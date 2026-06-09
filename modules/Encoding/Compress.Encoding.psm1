Set-StrictMode -Version Latest

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
        [int] $Pass,
        [int] $TotalPasses = 2
    )

    $progress = @{}
    $errorLines = New-Object System.Collections.Generic.List[string]
    $segment = 100.0 / $TotalPasses
    $basePercent = [int] [Math]::Floor(($Pass - 1) * $segment)
    $lastPercent = $basePercent

    if ($Pass -eq 1) {
        Write-CompressProgressBar $basePercent
    }

    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("compress-ffmpeg-" + [System.Guid]::NewGuid().ToString("N") + ".err")

    $exitCode = $null
    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        & ffmpeg @Arguments 2> $stderrPath | ForEach-Object {
            $line = $_.ToString()

            if ($line -match "^([^=]+)=(.*)$") {
                $progress[$Matches[1]] = $Matches[2]

                $seconds = Get-ProgressSeconds $progress
                if ($DurationSeconds -gt 0) {
                    $passPercent = [int] [Math]::Floor(($seconds / $DurationSeconds) * 100)
                    if ($passPercent -gt 100) { $passPercent = 100 }

                    $percent = $basePercent + [int] [Math]::Floor($passPercent * $segment / 100.0)
                    if ($percent -gt $lastPercent) {
                        Write-CompressProgressBar $percent
                        $lastPercent = $percent
                    }
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($line)) {
                $errorLines.Add($line)
            }
        }

        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference

        if (Test-Path -LiteralPath $stderrPath) {
            $stderrLines = Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue
            foreach ($line in $stderrLines) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $errorLines.Add($line)
                }
            }

            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($null -eq $exitCode) {
        $exitCode = 1
    }

    $finalPercent = [int] [Math]::Floor($Pass * $segment)
    if (($Pass -lt $TotalPasses) -and ($finalPercent -gt $lastPercent)) {
        Write-CompressProgressBar $finalPercent
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

function Require-FfmpegEncoder {
    param([string] $Name)

    $encoders = & ffmpeg -hide_banner -encoders 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect ffmpeg encoders."
    }

    if (-not (($encoders | Select-String -Pattern "\b$([regex]::Escape($Name))\b" -Quiet))) {
        throw "ffmpeg encoder '$Name' is not available."
    }
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

function Invoke-EncodeAttempt {
    param(
        [string] $InputPath,
        [string] $OutputPath,
        [int] $VideoKbps,
        [int] $AudioKbps,
        [bool] $HasAudio,
        [double] $DurationSeconds,
        [ValidateSet("x264", "nvenc")]
        [string] $EncoderMode = "x264"
    )

    if ($EncoderMode -eq "nvenc") {
        $encodeArgs = @(
            "-hide_banner", "-y", "-nostdin", "-loglevel", "error", "-nostats",
            "-progress", "pipe:1",
            "-i", $InputPath,
            "-map", "0:v:0",
            "-c:v", "h264_nvenc",
            "-preset", "p5",
            "-tune", "hq",
            "-rc", "vbr",
            "-multipass", "fullres",
            "-b:v", "${VideoKbps}k",
            "-maxrate", "${VideoKbps}k",
            "-bufsize", "$([Math]::Max($VideoKbps * 2, 64))k",
            "-rc-lookahead", "32",
            "-spatial-aq", "1",
            "-temporal-aq", "1",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart"
        )

        if ($HasAudio) {
            $encodeArgs += @("-map", "0:a:0?", "-c:a", "aac", "-b:a", "${AudioKbps}k", "-ac", "2")
        } else {
            $encodeArgs += @("-an")
        }

        $encodeArgs += @($OutputPath)
        Invoke-FfmpegWithProgress $encodeArgs $DurationSeconds 1 1
        return
    }

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
        Invoke-FfmpegWithProgress $pass1 $DurationSeconds 1 2
        Invoke-FfmpegWithProgress $pass2 $DurationSeconds 2 2
    } finally {
        Remove-PassLog $passLog
    }
}

function Invoke-LosslessCopy {
    param(
        [string] $InputPath,
        [string] $OutputPath,
        [double] $DurationSeconds
    )

    $copyArgs = @(
        "-hide_banner", "-y", "-nostdin", "-loglevel", "error", "-nostats",
        "-progress", "pipe:1",
        "-i", $InputPath,
        "-map", "0",
        "-c", "copy",
        "-movflags", "+faststart",
        $OutputPath
    )

    Invoke-FfmpegWithProgress $copyArgs $DurationSeconds 1 1
}

Export-ModuleMember -Function Get-AudioBitrateKbps, Invoke-EncodeAttempt, Invoke-LosslessCopy, Require-FfmpegEncoder
