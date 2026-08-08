[CmdletBinding()]
param(
    [ValidateSet('List', 'Expand', 'Select', 'Invoke', 'ApprovePrompt', 'ApproveWorkspaceTrust', 'ReadDocument', 'WaitText')]
    [string]$Action = 'List',

    [string]$ProcessName = 'claude',

    [string]$NameRegex = '.+',

    [ValidateSet('Any', 'Button', 'RadioButton', 'MenuItem', 'Text', 'Document')]
    [string]$ControlType = 'Any',

    [ValidateRange(1, 55)]
    [int]$TimeoutSeconds = 45,

    [ValidateRange(1, 30)]
    [int]$PollSeconds = 5,

    [string]$TextRegex = ''
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
        $expandPattern.Expand()
        Write-Output "expanded: $($element.Current.Name)"
        break
    }

    'Select' {
        $element = Get-UniqueElement -Root $root -Pattern $NameRegex -ExpectedType $ControlType
        $selectionPattern = $null
        if (-not $element.TryGetCurrentPattern(
                [System.Windows.Automation.SelectionItemPattern]::Pattern,
                [ref]$selectionPattern
            )) {
            throw "Control '$($element.Current.Name)' does not support SelectionItem."
        }
        $selectionPattern.Select()
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
            if ([regex]::IsMatch($document, $TextRegex)) {
                Write-Output $document
                exit 0
            }
            Start-Sleep -Seconds $PollSeconds
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        throw "Timed out after $TimeoutSeconds seconds waiting for /$TextRegex/."
    }
}
