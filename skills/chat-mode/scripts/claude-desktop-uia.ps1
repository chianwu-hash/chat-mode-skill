[CmdletBinding()]
param(
    [ValidateSet('List', 'Expand', 'Select', 'Invoke', 'ApprovePrompt', 'ApproveWorkspaceTrust', 'EnableBypass', 'DisableBypass', 'ReadDocument', 'WaitText')]
    [string]$Action = 'List',

    [string]$ProcessName = 'claude',

    [string]$NameRegex = '.+',

    [ValidateSet('Any', 'Button', 'RadioButton', 'MenuItem', 'Text', 'Document')]
    [string]$ControlType = 'Any',

    [ValidateRange(1, 55)]
    [int]$TimeoutSeconds = 45,

    [ValidateRange(1, 30)]
    [int]$PollSeconds = 5,

    [ValidateRange(1, 10)]
    [int]$MinimumTextMatches = 1,

    [string]$TextRegex = '',

    [string]$BypassContract = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Claude Desktop UI Automation is supported only on Windows.'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ChatModeWindowGuard
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
}
'@

function Get-ClaudeRoot {
    $windows = @(
        Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 }
    )

    if ($windows.Count -ne 1) {
        $details = ($windows | ForEach-Object {
                "pid=$($_.Id), handle=$($_.MainWindowHandle), title=$($_.MainWindowTitle)"
            }) -join '; '
        throw "Expected one $ProcessName main window, found $($windows.Count). $details"
    }

    $root = [System.Windows.Automation.AutomationElement]::FromHandle(
        [IntPtr]$windows[0].MainWindowHandle
    )

    if ($null -eq $root) {
        throw "Could not create a UI Automation root for $ProcessName."
    }

    return $root
}

function Test-ControlType {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [string]$Expected
    )

    if ($Expected -eq 'Any') {
        return $true
    }

    return $Element.Current.ControlType.ProgrammaticName -eq "ControlType.$Expected"
}

function Get-MatchingElements {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Pattern,
        [string]$ExpectedType,
        [int[]]$ProcessId = @()
    )

    $regex = [regex]::new($Pattern)
    $all = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    )

    $result = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $all.Count; $index++) {
        $element = $all.Item($index)
        $name = $element.Current.Name
        if (
            -not [string]::IsNullOrWhiteSpace($name) -and
            $regex.IsMatch($name) -and
            (Test-ControlType -Element $element -Expected $ExpectedType) -and
            ($ProcessId.Count -eq 0 -or $element.Current.ProcessId -in $ProcessId)
        ) {
            $result.Add($element)
        }
    }

    return $result.ToArray()
}

function Get-UniqueElement {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Pattern,
        [string]$ExpectedType,
        [int[]]$ProcessId = @()
    )

    $elements = @(Get-MatchingElements `
            -Root $Root `
            -Pattern $Pattern `
            -ExpectedType $ExpectedType `
            -ProcessId $ProcessId)
    if ($elements.Count -eq 0) {
        throw "No UI Automation control matched /$Pattern/ with type $ExpectedType."
    }
    if ($elements.Count -gt 1) {
        $names = ($elements | ForEach-Object {
                "$($_.Current.Name) [$($_.Current.ControlType.ProgrammaticName)]"
            }) -join '; '
        throw "Expected one UI Automation control, found $($elements.Count): $names"
    }

    return $elements[0]
}

function Get-DocumentText {
    param([System.Windows.Automation.AutomationElement]$Root)

    $all = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Subtree,
        [System.Windows.Automation.Condition]::TrueCondition
    )

    $longest = ''
    for ($index = 0; $index -lt $all.Count; $index++) {
        $element = $all.Item($index)
        $textPattern = $null
        if ($element.TryGetCurrentPattern(
                [System.Windows.Automation.TextPattern]::Pattern,
                [ref]$textPattern
            )) {
            $text = $textPattern.DocumentRange.GetText(-1)
            if ($text.Length -gt $longest.Length) {
                $longest = $text
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($longest)) {
        throw 'Claude exposed no readable UI Automation document text.'
    }

    return $longest
}

function Invoke-Element {
    param([System.Windows.Automation.AutomationElement]$Element)

    $invokePattern = $null
    if (-not $Element.TryGetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern,
            [ref]$invokePattern
        )) {
        throw "Control '$($Element.Current.Name)' does not support Invoke."
    }
    if (-not $Element.Current.IsEnabled) {
        throw "Control '$($Element.Current.Name)' is disabled."
    }
    if ($Element.Current.IsOffscreen) {
        throw "Control '$($Element.Current.Name)' is offscreen."
    }

    $invokePattern.Invoke()
}

function Select-Element {
    param([System.Windows.Automation.AutomationElement]$Element)

    $selectionPattern = $null
    if (-not $Element.TryGetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern,
            [ref]$selectionPattern
        )) {
        throw "Control '$($Element.Current.Name)' does not support SelectionItem."
    }
    if (-not $Element.Current.IsEnabled -or $Element.Current.IsOffscreen) {
        throw "Control '$($Element.Current.Name)' is not available."
    }

    $selectionPattern.Select()
}

function Open-ExpandedElement {
    param([System.Windows.Automation.AutomationElement]$Element)

    $expandPattern = $null
    if (-not $Element.TryGetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
            [ref]$expandPattern
        )) {
        throw "Control '$($Element.Current.Name)' does not support ExpandCollapse."
    }

    if (
        $expandPattern.Current.ExpandCollapseState -ne
        [System.Windows.Automation.ExpandCollapseState]::Collapsed
    ) {
        $expandPattern.Collapse()
        Start-Sleep -Milliseconds 100
        $expandPattern = $null
        if (-not $Element.TryGetCurrentPattern(
                [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
                [ref]$expandPattern
            )) {
            throw "Control '$($Element.Current.Name)' lost ExpandCollapse after reset."
        }
    }

    $expandPattern.Expand()
}

function Reset-CollapsedElement {
    param([System.Windows.Automation.AutomationElement]$Element)

    $expandPattern = $null
    if (-not $Element.TryGetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
            [ref]$expandPattern
        )) {
        throw "Control '$($Element.Current.Name)' does not support ExpandCollapse."
    }
    if (
        $expandPattern.Current.ExpandCollapseState -ne
        [System.Windows.Automation.ExpandCollapseState]::Collapsed
    ) {
        $expandPattern.Collapse()
        Start-Sleep -Milliseconds 100
    }
}

function Invoke-GuardedFocusedSpace {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [System.Windows.Automation.AutomationElement]$WindowRoot
    )

    $windowHandle = [IntPtr]$WindowRoot.Current.NativeWindowHandle
    if ($windowHandle -eq [IntPtr]::Zero) {
        throw 'Claude main window has no native handle for the guarded keyboard fallback.'
    }
    if ([ChatModeWindowGuard]::GetForegroundWindow() -ne $windowHandle) {
        throw 'Claude is not foreground; refusing the guarded keyboard fallback.'
    }

    $Element.SetFocus()
    Start-Sleep -Milliseconds 100
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if (
        $focused.Current.ProcessId -ne $Element.Current.ProcessId -or
        $focused.Current.Name -ne $Element.Current.Name -or
        $focused.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button
    ) {
        throw "Focus guard failed for '$($Element.Current.Name)'."
    }
    if ([ChatModeWindowGuard]::GetForegroundWindow() -ne $windowHandle) {
        throw 'Foreground changed before the guarded keyboard fallback.'
    }

    [System.Windows.Forms.SendKeys]::SendWait(' ')
}

function Get-AncestorWindow {
    param([System.Windows.Automation.AutomationElement]$Element)

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $current = $Element
    while ($null -ne $current) {
        if ($current.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window) {
            return $current
        }
        $current = $walker.GetParent($current)
    }

    throw "No ancestor window was found for '$($Element.Current.Name)'."
}

function Assert-SpecificTextRegex {
    param([string]$Pattern)

    if (
        [string]::IsNullOrWhiteSpace($Pattern) -or
        $Pattern.Length -lt 8 -or
        $Pattern -in @('.*', '.+', '^.*$', '^.+$')
    ) {
        throw 'Approval actions require a contract-specific -TextRegex.'
    }

    $null = [regex]::new($Pattern)
}

$root = Get-ClaudeRoot

switch ($Action) {
    'List' {
        Get-MatchingElements -Root $root -Pattern $NameRegex -ExpectedType $ControlType |
            ForEach-Object {
                $patterns = ($_.GetSupportedPatterns() | ForEach-Object {
                        $_.ProgrammaticName -replace 'PatternIdentifiers.Pattern$', ''
                    }) -join ','
                [PSCustomObject]@{
                    Name        = $_.Current.Name
                    ControlType = $_.Current.ControlType.ProgrammaticName
                    Patterns    = $patterns
                    Enabled     = $_.Current.IsEnabled
                    Offscreen   = $_.Current.IsOffscreen
                }
            }
        break
    }

    'Expand' {
        $element = Get-UniqueElement -Root $root -Pattern $NameRegex -ExpectedType $ControlType
        $expandPattern = $null
        if (-not $element.TryGetCurrentPattern(
                [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
                [ref]$expandPattern
            )) {
            throw "Control '$($element.Current.Name)' does not support ExpandCollapse."
        }
        if (
            $expandPattern.Current.ExpandCollapseState -eq
            [System.Windows.Automation.ExpandCollapseState]::Collapsed
        ) {
            $expandPattern.Expand()
        }
        Write-Output "expanded: $($element.Current.Name)"
        break
    }

    'Select' {
        $element = Get-UniqueElement -Root $root -Pattern $NameRegex -ExpectedType $ControlType
        Select-Element -Element $element
        Write-Output "selected: $($element.Current.Name)"
        break
    }

    'Invoke' {
        $element = Get-UniqueElement -Root $root -Pattern $NameRegex -ExpectedType $ControlType
        Invoke-Element -Element $element
        Write-Output "invoked: $($element.Current.Name)"
        break
    }

    'ApprovePrompt' {
        Assert-SpecificTextRegex -Pattern $TextRegex

        $trustElements = @(Get-MatchingElements `
                -Root $root `
                -Pattern '(?i)^Trust this workspace\?$' `
                -ExpectedType 'Any')
        if ($trustElements.Count -gt 0) {
            throw 'ApprovePrompt refuses workspace trust dialogs.'
        }

        $prompt = Get-UniqueElement `
            -Root $root `
            -Pattern $TextRegex `
            -ExpectedType 'Any'
        if (-not $prompt.Current.IsEnabled -or $prompt.Current.IsOffscreen) {
            throw "Prompt control '$($prompt.Current.Name)' is not available."
        }

        $allow = Get-UniqueElement `
            -Root $root `
            -Pattern '^Allow once(?:\s+\d+)?$' `
            -ExpectedType 'Button'
        $deny = Get-UniqueElement `
            -Root $root `
            -Pattern '^Deny(?:\s+\d+)?$' `
            -ExpectedType 'Button'
        if (-not $deny.Current.IsEnabled -or $deny.Current.IsOffscreen) {
            throw "Control '$($deny.Current.Name)' is not available."
        }

        $allowName = $allow.Current.Name
        Invoke-Element -Element $allow
        Write-Output "approved prompt once: $allowName"
        break
    }

    'ApproveWorkspaceTrust' {
        Assert-SpecificTextRegex -Pattern $TextRegex

        $trustHeadings = @(Get-MatchingElements `
                -Root $root `
                -Pattern '(?i)^Trust this workspace\?$' `
                -ExpectedType 'Any')
        if ($trustHeadings.Count -eq 0) {
            throw 'No workspace trust dialog was detected.'
        }

        $path = Get-UniqueElement `
            -Root $root `
            -Pattern $TextRegex `
            -ExpectedType 'Any'
        if (-not $path.Current.IsEnabled -or $path.Current.IsOffscreen) {
            throw "Workspace path control '$($path.Current.Name)' is not available."
        }

        $trust = Get-UniqueElement `
            -Root $root `
            -Pattern '^Trust Workspace(?:\s+\d+)?$' `
            -ExpectedType 'Button'
        $cancel = Get-UniqueElement `
            -Root $root `
            -Pattern '^Cancel(?:\s+\d+)?$' `
            -ExpectedType 'Button'
        if (-not $cancel.Current.IsEnabled -or $cancel.Current.IsOffscreen) {
            throw "Control '$($cancel.Current.Name)' is not available."
        }

        $trustName = $trust.Current.Name
        Invoke-Element -Element $trust
        Write-Output "approved workspace trust: $trustName"
        break
    }

    'EnableBypass' {
        $allowedBypassContracts = @(
            'review-readonly'
            'direct-main-exclusive'
        )
        if ($BypassContract -notin $allowedBypassContracts) {
            throw 'EnableBypass requires -BypassContract review-readonly or direct-main-exclusive.'
        }

        $currentMode = Get-UniqueElement `
            -Root $root `
            -Pattern '^(?:Manual|Accept edits|Bypass permissions)$' `
            -ExpectedType 'Button'
        if ($currentMode.Current.Name -eq 'Bypass permissions') {
            Write-Output "already enabled: Bypass permissions ($BypassContract)"
            break
        }
        $claudeProcessId = @(Get-Process -Name $ProcessName -ErrorAction Stop |
                ForEach-Object { $_.Id })
        $desktopRoot = [System.Windows.Automation.AutomationElement]::RootElement
        Open-ExpandedElement -Element $currentMode

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        do {
            $bypassOptions = @(Get-MatchingElements `
                    -Root $desktopRoot `
                    -Pattern '^Bypass permissions\b' `
                    -ExpectedType 'RadioButton' `
                    -ProcessId $claudeProcessId)
            if ($bypassOptions.Count -gt 0) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        if ($bypassOptions.Count -eq 0) {
            Reset-CollapsedElement -Element $currentMode
            Invoke-GuardedFocusedSpace -Element $currentMode -WindowRoot $root
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
            do {
                $bypassOptions = @(Get-MatchingElements `
                        -Root $desktopRoot `
                        -Pattern '^Bypass permissions\b' `
                        -ExpectedType 'RadioButton' `
                        -ProcessId $claudeProcessId)
                if ($bypassOptions.Count -gt 0) {
                    break
                }
                Start-Sleep -Milliseconds 250
            } while ([DateTimeOffset]::UtcNow -lt $deadline)
        }

        if ($bypassOptions.Count -ne 1) {
            throw "Expected one Bypass permission option, found $($bypassOptions.Count)."
        }
        $bypassOption = $bypassOptions[0]
        Select-Element -Element $bypassOption

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        do {
            $titles = @(Get-MatchingElements `
                    -Root $desktopRoot `
                    -Pattern '^Bypass all permissions\?$' `
                    -ExpectedType 'Any' `
                    -ProcessId $claudeProcessId)
            $modeButtons = @(Get-MatchingElements `
                    -Root $root `
                    -Pattern '^Bypass permissions$' `
                    -ExpectedType 'Button')
            if ($titles.Count -gt 0 -or $modeButtons.Count -gt 0) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        if ($titles.Count -eq 0 -and $modeButtons.Count -eq 1) {
            Write-Output "enabled: Bypass permissions ($BypassContract; warning previously acknowledged)"
            break
        }
        if ($titles.Count -eq 0) {
            throw 'Bypass confirmation title and final mode are both missing.'
        }
        $dialogRoots = @($titles | ForEach-Object {
                Get-AncestorWindow -Element $_
            })
        $dialogRuntimeIds = @($dialogRoots | ForEach-Object {
                $_.GetRuntimeId() -join '.'
            } | Sort-Object -Unique)
        if ($dialogRuntimeIds.Count -ne 1) {
            throw "Bypass title controls span $($dialogRuntimeIds.Count) dialog windows."
        }
        $dialogRoot = $dialogRoots[0]
        $confirmButton = Get-UniqueElement `
            -Root $dialogRoot `
            -Pattern '^Bypass permissions$' `
            -ExpectedType 'Button'
        $warning = Get-UniqueElement `
            -Root $dialogRoot `
            -Pattern '^Claude will read, edit, and execute files without asking' `
            -ExpectedType 'Text'
        if (-not $warning.Current.IsEnabled -or $warning.Current.IsOffscreen) {
            throw 'Bypass warning text is not available.'
        }
        $cancel = Get-UniqueElement `
            -Root $dialogRoot `
            -Pattern '^Cancel$' `
            -ExpectedType 'Button'
        if (-not $cancel.Current.IsEnabled -or $cancel.Current.IsOffscreen) {
            throw 'Bypass Cancel control is not available.'
        }

        Invoke-Element -Element $confirmButton
        Start-Sleep -Milliseconds 500
        $null = Get-UniqueElement `
            -Root $root `
            -Pattern '^Bypass permissions$' `
            -ExpectedType 'Button'
        Write-Output "enabled: Bypass permissions ($BypassContract)"
        break
    }

    'DisableBypass' {
        $currentMode = Get-UniqueElement `
            -Root $root `
            -Pattern '^(?:Manual|Accept edits|Bypass permissions)$' `
            -ExpectedType 'Button'
        if ($currentMode.Current.Name -eq 'Manual') {
            Write-Output 'already selected: Manual'
            break
        }
        $claudeProcessId = @(Get-Process -Name $ProcessName -ErrorAction Stop |
                ForEach-Object { $_.Id })
        $desktopRoot = [System.Windows.Automation.AutomationElement]::RootElement
        Open-ExpandedElement -Element $currentMode

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        do {
            $manualOptions = @(Get-MatchingElements `
                    -Root $desktopRoot `
                    -Pattern '^Manual\b' `
                    -ExpectedType 'RadioButton' `
                    -ProcessId $claudeProcessId)
            if ($manualOptions.Count -gt 0) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        if ($manualOptions.Count -eq 0) {
            Reset-CollapsedElement -Element $currentMode
            Invoke-GuardedFocusedSpace -Element $currentMode -WindowRoot $root
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
            do {
                $manualOptions = @(Get-MatchingElements `
                        -Root $desktopRoot `
                        -Pattern '^Manual\b' `
                        -ExpectedType 'RadioButton' `
                        -ProcessId $claudeProcessId)
                if ($manualOptions.Count -gt 0) {
                    break
                }
                Start-Sleep -Milliseconds 250
            } while ([DateTimeOffset]::UtcNow -lt $deadline)
        }
        if ($manualOptions.Count -ne 1) {
            throw "Expected one Manual option, found $($manualOptions.Count)."
        }
        $manual = $manualOptions[0]
        Select-Element -Element $manual

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        do {
            $manualButtons = @(Get-MatchingElements `
                    -Root $root `
                    -Pattern '^Manual$' `
                    -ExpectedType 'Button')
            if ($manualButtons.Count -gt 0) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        if ($manualButtons.Count -ne 1) {
            throw "Expected one Manual mode button, found $($manualButtons.Count)."
        }
        Write-Output 'selected: Manual'
        break
    }

    'ReadDocument' {
        Write-Output (Get-DocumentText -Root $root)
        break
    }

    'WaitText' {
        if ([string]::IsNullOrWhiteSpace($TextRegex)) {
            throw '-TextRegex is required for WaitText.'
        }

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $document = Get-DocumentText -Root $root
            $matchCount = [regex]::Matches($document, $TextRegex).Count
            if ($matchCount -ge $MinimumTextMatches) {
                Write-Output $document
                exit 0
            }
            Start-Sleep -Seconds $PollSeconds
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        throw "Timed out after $TimeoutSeconds seconds waiting for $MinimumTextMatches matches of /$TextRegex/."
    }
}
