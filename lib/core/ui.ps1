# Mole - UI Module
# Provides interactive UI components (menus, confirmations, etc.)

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_UI_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_UI_LOADED) { return }
$script:MOLE_UI_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\base.ps1"
. "$scriptDir\log.ps1"

# ============================================================================
# Terminal Utilities
# ============================================================================

function Get-TerminalSize {
    <#
    .SYNOPSIS
        Get terminal width and height
    #>
    try {
        return @{
            Width  = $Host.UI.RawUI.WindowSize.Width
            Height = $Host.UI.RawUI.WindowSize.Height
        }
    }
    catch {
        return @{ Width = 80; Height = 24 }
    }
}

# PowerShell 7 throws "The handle is invalid" when Clear-Host runs with
# redirected output. A preview written to a file or pipe must still run.
function Clear-MoleScreen {
    try {
        if ([Console]::IsOutputRedirected) { return }
        Clear-Host
    }
    catch { }
}

# Measure terminal cells, not UTF-16 length. ConsoleHost's own width helper
# counts CJK as one cell on Windows, so it cannot align mixed-language rows.
function Get-TerminalTextWidth {
    param([string]$Text)
    $width = 0
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = $elements.GetTextElement()
        $point = [char]::ConvertToUtf32($element, 0)
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($element, 0)
        if ($category -in @('NonSpacingMark', 'EnclosingMark', 'Format', 'Control')) { continue }
        if (($point -ge 0x1100 -and $point -le 0x115f) -or
            ($point -ge 0x2329 -and $point -le 0x232a) -or
            ($point -ge 0x2e80 -and $point -le 0xa4cf -and $point -ne 0x303f) -or
            ($point -ge 0xac00 -and $point -le 0xd7a3) -or
            ($point -ge 0xf900 -and $point -le 0xfaff) -or
            ($point -ge 0xfe10 -and $point -le 0xfe19) -or
            ($point -ge 0xfe30 -and $point -le 0xfe6f) -or
            ($point -ge 0xff00 -and $point -le 0xff60) -or
            ($point -ge 0xffe0 -and $point -le 0xffe6) -or
            ($point -ge 0x1f300 -and $point -le 0x1faff) -or
            ($point -ge 0x20000 -and $point -le 0x3fffd)) { $width += 2 }
        else { $width++ }
    }
    return $width
}

function Format-SizeListEntry {
    param([string]$Name, [string]$Size, [string]$Suffix = '', [int]$NameWidth = 42, [switch]$KeepEnd)
    # Leave six cells for the caller's selection prefix and one spare column
    # so writing the rightmost size never triggers terminal auto-wrap.
    $budget = [Math]::Max(1, (Get-TerminalSize).Width - 18 - (Get-TerminalTextWidth $Suffix))
    $nameCells = [Math]::Min($NameWidth, $budget)
    $nameText = $Name -replace '[\x00-\x1f\x7f]', ' '
    if ((Get-TerminalTextWidth $nameText) -gt $nameCells) {
        $ending = '.' * [Math]::Min(3, $nameCells)
        $limit = $nameCells - $ending.Length
        $parts = New-Object Collections.Generic.List[string]
        $elements = [Globalization.StringInfo]::GetTextElementEnumerator($nameText)
        while ($elements.MoveNext()) { $parts.Add($elements.GetTextElement()) }
        # A path is told apart by its last folders, so -KeepEnd drops the start.
        if ($KeepEnd) { $parts.Reverse() }
        $kept = New-Object Collections.Generic.List[string]
        $used = 0
        foreach ($element in $parts) {
            $cells = Get-TerminalTextWidth $element
            if ($used + $cells -gt $limit) { break }
            $kept.Add($element)
            $used += $cells
        }
        if ($KeepEnd) {
            $kept.Reverse()
            $nameText = $ending + ($kept -join '')
        }
        else { $nameText = ($kept -join '') + $ending }
    }
    $padding = ' ' * [Math]::Max(0, $nameCells - (Get-TerminalTextWidth $nameText))
    return $nameText + $padding + ' ' + $Size.PadLeft(10) + $Suffix
}

# ============================================================================
# Banner / Header
# ============================================================================

function Show-Banner {
    <#
    .SYNOPSIS
        Display the Mole logo, website and tagline, as the macOS CLI does
    #>
    $green = $script:Colors.Green
    $blue = $script:Colors.Blue
    $nc = $script:Colors.NC

    Write-Host "$green __  __       _      $nc"
    Write-Host "$green|  \/  | ___ | | ___ $nc"
    Write-Host "$green| |\/| |/ _ \| |/ _ \$nc"
    Write-Host "$green| |  | | (_) | |  __/$nc  ${blue}https://mole.fit/windows$nc"
    Write-Host "$green|_|  |_|\___/|_|\___|$nc  ${green}Deep clean and optimize your PC.$nc"
    Write-Host ""
}

# ============================================================================
# Summary Display
# ============================================================================

function Show-SummaryBlock {
    param([string]$Heading, [string[]]$Details = @())
    Stop-Spinner
    # Let the last result settle before the final frame, without faking work.
    if (Test-MoleInteractiveOutput) { Start-Sleep -Milliseconds 180 }
    $width = [Math]::Max(1, [Math]::Min(70, (Get-TerminalSize).Width))
    $divider = '=' * $width
    Write-Host ""
    Write-Host $divider
    Write-Host "$(Get-MoleColor -Name Blue)$Heading$(Get-MoleColor -Name NC)"
    foreach ($detail in $Details) {
        if ($detail) { Write-Host $detail }
    }
    Write-Host $divider
    # Keep the shell prompt off the closing divider.
    Write-Host ""
}

# ============================================================================
# Exports (functions are available via dot-sourcing)
# ============================================================================
# Functions: Show-Banner, Format-SizeListEntry, Show-SummaryBlock, etc.
