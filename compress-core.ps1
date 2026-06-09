# Internal implementation for compress.bat.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Path,

    [Parameter(Position = 1)]
    [double] $MaxMB = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Format-Size {
    param([long] $Bytes)
    return ("{0:N2} MB" -f ($Bytes / 1MB))
}

function Require-Command {
    param([string] $Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' is not available in PATH."
    }
}

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

function Write-ProgressBar {
    param(
        [int] $Percent
    )

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
    } else {
        try {
            $maxWidth = [Math]::Max(20, [Console]::WindowWidth - 1)
        } catch {
            $maxWidth = 100
        }

        if ($line.Length -gt $maxWidth) {
            $line = $line.Substring(0, $maxWidth)
        }
        $line = $line.PadRight($maxWidth)
        Write-Host -NoNewline "`r$line"
    }
}

function Get-ProgressSeconds {
    param([hashtable] $Progress)

    foreach ($key in @("out_time_us", "out_time_ms")) {
        if ($Progress.ContainsKey($key)) {
            $raw = $Progress[$key]
            $value = 0L
            if ([long]::TryParse($raw, [ref] $value)) {
                return $value / 1000000.0
            }
        }
    }

    if ($Progress.ContainsKey("out_time")) {
        $span = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse($Progress["out_time"], [ref] $span)) {
            return $span.TotalSeconds
        }
    }

    return 0.0
}

function Invoke-FfmpegWithProgress {
    param(
        [string[]] $Arguments,
        [double] $DurationSeconds,
        [int] $Attempt,
        [int] $MaxAttempts,
        [int] $Pass,
        [string] $PassLabel,
        [string] $FileName
    )

    $progress = @{}
    $errorLines = New-Object System.Collections.Generic.List[string]
    $basePercent = ($Pass - 1) * 50
    $lastPercent = $basePercent
    if ($Pass -eq 1) {
        Write-ProgressBar $basePercent
    }

    & ffmpeg @Arguments 2>&1 | ForEach-Object {
        $line = $_.ToString()

        if ($line -match "^([^=]+)=(.*)$") {
            $progress[$Matches[1]] = $Matches[2]

            $seconds = Get-ProgressSeconds $progress
            if ($DurationSeconds -gt 0) {
                $passPercent = [int] [Math]::Floor(($seconds / $DurationSeconds) * 100)
                if ($passPercent -gt 100) { $passPercent = 100 }
                $percent = $basePercent + [int] [Math]::Floor($passPercent / 2)

                if ($percent -gt $lastPercent) {
                    Write-ProgressBar $percent
                    $lastPercent = $percent
                }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($line)) {
            $errorLines.Add($line)
        }
    }

    $exitCode = $LASTEXITCODE
    $finalPercent = $basePercent + 50
    if (($Pass -lt 2) -and ($finalPercent -gt $lastPercent)) {
        Write-ProgressBar $finalPercent
    }

    if ($exitCode -ne 0) {
        $message = if ($errorLines.Count -gt 0) {
            $errorLines -join [Environment]::NewLine
        } else {
            "ffmpeg failed with exit code $exitCode."
        }

        throw $message
    }
}

function Get-VideoDurationSeconds {
    param([string] $InputPath)

    $duration = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $InputPath
    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe failed to read video duration."
    }

    $value = ($duration | Select-Object -First 1).Trim()
    return [double]::Parse($value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-HasAudio {
    param([string] $InputPath)

    $audio = & ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 $InputPath
    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe failed to inspect audio streams."
    }

    return -not [string]::IsNullOrWhiteSpace(($audio | Select-Object -First 1))
}

function Get-AudioBitrateKbps {
    param(
        [bool] $HasAudio,
        [int] $TotalKbps
    )

    if (-not $HasAudio) {
        return 0
    }

    if ($TotalKbps -ge 700) { return 128 }
    if ($TotalKbps -ge 400) { return 96 }
    if ($TotalKbps -ge 220) { return 64 }
    return 48
}

function Remove-PassLog {
    param([string] $PassLog)

    $paths = @(
        "$PassLog.log",
        "$PassLog.log.mbtree",
        "$PassLog-0.log",
        "$PassLog-0.log.mbtree"
    )

    foreach ($item in $paths) {
        Remove-Item -LiteralPath $item -Force -ErrorAction SilentlyContinue
    }
}

function Move-WithRetry {
    param(
        [string] $Source,
        [string] $Destination
    )

    $lastError = $null

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
            }

            Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 300
        }
    }

    throw $lastError
}

function Invoke-EncodeAttempt {
    param(
        [string] $InputPath,
        [string] $OutputPath,
        [int] $VideoKbps,
        [int] $AudioKbps,
        [bool] $HasAudio,
        [double] $DurationSeconds,
        [int] $Attempt,
        [int] $MaxAttempts,
        [string] $FileName
    )

    $passLog = Join-Path ([System.IO.Path]::GetTempPath()) ("compress-" + [System.Guid]::NewGuid().ToString("N"))

    $pass1 = @(
        "-hide_banner", "-y", "-nostdin", "-loglevel", "error", "-nostats",
        "-progress", "pipe:1",
        "-i", $InputPath,
        "-map", "0:v:0",
        "-c:v", "libx264",
        "-preset", "slow",
        "-b:v", "${VideoKbps}k",
        "-pix_fmt", "yuv420p",
        "-pass", "1",
        "-passlogfile", $passLog,
        "-an",
        "-f", "null",
        "NUL"
    )

    $pass2 = @(
        "-hide_banner", "-y", "-nostdin", "-loglevel", "error", "-nostats",
        "-progress", "pipe:1",
        "-i", $InputPath,
        "-map", "0:v:0",
        "-c:v", "libx264",
        "-preset", "slow",
        "-b:v", "${VideoKbps}k",
        "-pix_fmt", "yuv420p",
        "-pass", "2",
        "-passlogfile", $passLog,
        "-movflags", "+faststart"
    )

    if ($HasAudio) {
        $pass2 += @("-map", "0:a:0?", "-c:a", "aac", "-b:a", "${AudioKbps}k", "-ac", "2")
    } else {
        $pass2 += @("-an")
    }

    $pass2 += @($OutputPath)

    try {
        Invoke-FfmpegWithProgress $pass1 $DurationSeconds $Attempt $MaxAttempts 1 "analysis" $FileName
        Invoke-FfmpegWithProgress $pass2 $DurationSeconds $Attempt $MaxAttempts 2 "write mp4" $FileName
    } finally {
        Remove-PassLog $passLog
    }
}

try {
    Require-Command "ffmpeg"
    Require-Command "ffprobe"

    $inputItem = Get-Item -LiteralPath $Path
    if ($inputItem.PSIsContainer) {
        throw "Input path is a directory, expected a video file."
    }

    $targetBytes = [long] [Math]::Floor($MaxMB * 1MB)
    $closeEnoughBytes = [long] [Math]::Floor($targetBytes * 0.985)
    $inputFullPath = $inputItem.FullName
    $directory = $inputItem.DirectoryName
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputItem.Name)
    $outputPath = Join-Path $directory "$baseName-compressed.mp4"

    if ($inputItem.Length -le $targetBytes) {
        Copy-Item -LiteralPath $inputFullPath -Destination $outputPath -Force
        Write-ProgressBar 100
        Write-Host
        Write-Host "Compressed into $([System.IO.Path]::GetFileName($outputPath))"
        exit 0
    }

    $duration = Get-VideoDurationSeconds $inputFullPath
    if ($duration -le 0) {
        throw "Video duration is invalid."
    }

    $hasAudio = Test-HasAudio $inputFullPath
    $initialBudgetBytes = [long] [Math]::Floor($targetBytes * 0.992)
    $totalKbps = [int] [Math]::Floor(($initialBudgetBytes * 8 / $duration) / 1000)
    $audioKbps = Get-AudioBitrateKbps $hasAudio $totalKbps
    $minimumVideoKbps = 32
    $videoKbps = [Math]::Max($minimumVideoKbps, $totalKbps - $audioKbps)
    $maxAttempts = 6
    $lowGoodKbps = $null
    $highBadKbps = $null
    $bestGoodPath = $null
    $bestGoodSize = 0L

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $candidatePath = Join-Path $directory ("$baseName-compressed.attempt-$attempt.mp4")
        Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue

        Invoke-EncodeAttempt $inputFullPath $candidatePath $videoKbps $audioKbps $hasAudio $duration $attempt $maxAttempts $inputItem.Name

        $candidateSize = (Get-Item -LiteralPath $candidatePath).Length

        if ($candidateSize -le $targetBytes) {
            if ($candidateSize -gt $bestGoodSize) {
                if ($bestGoodPath -and (Test-Path -LiteralPath $bestGoodPath)) {
                    Remove-Item -LiteralPath $bestGoodPath -Force
                }
                $bestGoodPath = $candidatePath
                $bestGoodSize = $candidateSize
            } else {
                Remove-Item -LiteralPath $candidatePath -Force
            }

            $lowGoodKbps = $videoKbps

            if ($candidateSize -ge $closeEnoughBytes) {
                break
            }

            if ($null -ne $highBadKbps) {
                $nextKbps = [int] [Math]::Floor(($lowGoodKbps + $highBadKbps) / 2)
            } else {
                $ratio = $targetBytes / [double] $candidateSize
                $nextKbps = [int] [Math]::Floor($videoKbps * $ratio * 0.995)
            }

            if ($nextKbps -le $videoKbps) {
                break
            }

            $videoKbps = $nextKbps
            continue
        }

        Remove-Item -LiteralPath $candidatePath -Force
        $highBadKbps = $videoKbps

        if ($null -ne $lowGoodKbps) {
            $nextKbps = [int] [Math]::Floor(($lowGoodKbps + $highBadKbps) / 2)
        } else {
            $ratio = $targetBytes / [double] $candidateSize
            $nextKbps = [int] [Math]::Floor($videoKbps * $ratio * 0.985)
        }

        if ($nextKbps -ge $videoKbps) {
            $nextKbps = $videoKbps - 16
        }

        if ($nextKbps -lt $minimumVideoKbps) {
            $nextKbps = $minimumVideoKbps
        }

        if ($nextKbps -eq $videoKbps) {
            break
        }

        $videoKbps = $nextKbps
    }

    if (-not $bestGoodPath) {
        throw "Could not compress below $(Format-Size $targetBytes) within $maxAttempts attempts."
    }

    Move-WithRetry $bestGoodPath $outputPath

    Get-ChildItem -LiteralPath $directory -Filter "$baseName-compressed.attempt-*.mp4" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-ProgressBar 100
    Write-Host
    Write-Host "Compressed into $([System.IO.Path]::GetFileName($outputPath))"
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
