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
        [string]$ExpectedType
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
            (Test-ControlType -Element $element -Expected $ExpectedType)
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
        [string]$ExpectedType
    )

    $elements = @(Get-MatchingElements -Root $Root -Pattern $Pattern -ExpectedType $ExpectedType)
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
        if ($BypassContract -ne 'direct-main-exclusive') {
            throw "EnableBypass requires -BypassContract 'direct-main-exclusive'."
        }

        $currentMode = Get-UniqueElement `
            -Root $root `
            -Pattern '^(?:Manual|Accept edits)$' `
            -ExpectedType 'Button'
        $expandPattern = $null
        if (-not $currentMode.TryGetCurrentPattern(
                [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
                [ref]$expandPattern
            )) {
            throw "Control '$($currentMode.Current.Name)' does not support ExpandCollapse."
        }
        if (
            $expandPattern.Current.ExpandCollapseState -eq
            [System.Windows.Automation.ExpandCollapseState]::Collapsed
        ) {
            $expandPattern.Expand()
        }

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        do {
            $bypassOptions = @(Get-MatchingElements `
                    -Root $root `
                    -Pattern '^Bypass permissions\b' `
                    -ExpectedType 'RadioButton')
            if ($bypassOptions.Count -gt 0) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        if ($bypassOptions.Count -ne 1) {
            throw "Expected one Bypass permission option, found $($bypassOptions.Count)."
        }
        $bypassOption = $bypassOptions[0]
        Select-Element -Element $bypassOption

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        do {
            $confirmButtons = @(Get-MatchingElements `
                    -Root $root `
                    -Pattern '^Bypass permissions$' `
                    -ExpectedType 'Button')
            if ($confirmButtons.Count -gt 0) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        if ($confirmButtons.Count -ne 1) {
            throw "Expected one Bypass confirmation button, found $($confirmButtons.Count)."
        }

        $titles = @(Get-MatchingElements `
                -Root $root `
                -Pattern '^Bypass all permissions\?$' `
                -ExpectedType 'Any')
        if ($titles.Count -eq 0) {
            throw 'Bypass confirmation title is missing.'
        }
        $warning = Get-UniqueElement `
            -Root $root `
            -Pattern '^Claude will read, edit, and execute files without asking' `
            -ExpectedType 'Text'
        if (-not $warning.Current.IsEnabled -or $warning.Current.IsOffscreen) {
            throw 'Bypass warning text is not available.'
        }
        $cancel = Get-UniqueElement `
            -Root $root `
            -Pattern '^Cancel$' `
            -ExpectedType 'Button'
        if (-not $cancel.Current.IsEnabled -or $cancel.Current.IsOffscreen) {
            throw 'Bypass Cancel control is not available.'
        }

        Invoke-Element -Element $confirmButtons[0]
        Start-Sleep -Milliseconds 500
        $null = Get-UniqueElement `
            -Root $root `
            -Pattern '^Bypass permissions$' `
            -ExpectedType 'Button'
        Write-Output 'enabled: Bypass permissions'
        break
    }

    'DisableBypass' {
        $currentMode = Get-UniqueElement `
            -Root $root `
            -Pattern '^Bypass permissions$' `
            -ExpectedType 'Button'
        $expandPattern = $null
        if (-not $currentMode.TryGetCurrentPattern(
                [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
                [ref]$expandPattern
            )) {
            throw "Control '$($currentMode.Current.Name)' does not support ExpandCollapse."
        }
        if (
            $expandPattern.Current.ExpandCollapseState -eq
            [System.Windows.Automation.ExpandCollapseState]::Collapsed
        ) {
            $expandPattern.Expand()
        }

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        do {
            $manualOptions = @(Get-MatchingElements `
                    -Root $root `
                    -Pattern '^Manual\b' `
                    -ExpectedType 'RadioButton')
            if ($manualOptions.Count -gt 0) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
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
        Write-Output 'disabled Bypass permissions; selected: Manual'
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
