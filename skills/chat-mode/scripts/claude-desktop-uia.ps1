[CmdletBinding()]
param(
    [ValidateSet('List', 'Expand', 'Select', 'Invoke', 'ReadDocument', 'WaitText')]
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
        $invokePattern = $null
        if (-not $element.TryGetCurrentPattern(
                [System.Windows.Automation.InvokePattern]::Pattern,
                [ref]$invokePattern
            )) {
            throw "Control '$($element.Current.Name)' does not support Invoke."
        }
        $invokePattern.Invoke()
        Write-Output "invoked: $($element.Current.Name)"
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
