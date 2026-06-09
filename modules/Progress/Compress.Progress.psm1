Set-StrictMode -Version Latest

function Get-BarWidth {
    try {
        $windowWidth = [Console]::WindowWidth
        $available = $windowWidth - 9
        if ($available -gt 56) { return 56 }
        if ($available -gt 28) { return $available }
    } catch {
        return 32
    }

    return 24
}

function Test-AnsiOutput {
    try {
        return (-not [Console]::IsOutputRedirected) -and [string]::IsNullOrEmpty($env:NO_COLOR)
    } catch {
        return $false
    }
}

function Add-AnsiColor {
    param(
        [string] $Text,
        [string] $Code
    )

    if (-not (Test-AnsiOutput)) {
        return $Text
    }

    $esc = [char] 27
    return "$esc[${Code}m$Text$esc[0m"
}

function Write-CompressProgressBar {
    param([int] $Percent)

    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    $width = Get-BarWidth
    $filled = [int] [Math]::Floor($width * ($Percent / 100.0))
    if ($filled -gt $width) { $filled = $width }

    $fillChar = [char] 0x2588
    $emptyChar = [char] 0x28FF
    $filledText = "$fillChar" * $filled
    $emptyText = "$emptyChar" * ($width - $filled)
    $bar = "$(Add-AnsiColor $filledText '38;2;122;92;255')$(Add-AnsiColor $emptyText '38;2;82;82;92')"
    $line = ('{0} {1:000}/100' -f $bar, $Percent)

    if (Test-AnsiOutput) {
        $esc = [char] 27
        Write-Host -NoNewline "`r$line$esc[K"
        return
    }

    try {
        $maxWidth = [Math]::Max(20, [Console]::WindowWidth - 1)
    } catch {
        $maxWidth = 100
    }

    if ($line.Length -gt $maxWidth) {
        $line = $line.Substring(0, $maxWidth)
    }

    Write-Host -NoNewline "`r$($line.PadRight($maxWidth))"
}

Export-ModuleMember -Function Write-CompressProgressBar
