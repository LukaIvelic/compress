# Internal implementation for compress.bat.
[CmdletBinding()]
param(
    [Alias("d")]
    [switch] $Directory,

    [Alias("n")]
    [switch] $Nvidia,

    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Path,

    [Parameter(Position = 1)]
    [double] $MaxMB = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-CompressVideo {
    param(
        [System.IO.FileInfo] $InputItem,
        [double] $TargetMB,
        [string] $EncoderMode
    )

    $targetBytes = [long] [Math]::Floor($TargetMB * 1MB)
    $closeEnoughFactor = if ($EncoderMode -eq "nvenc") { 0.94 } else { 0.985 }
    $closeEnoughBytes = [long] [Math]::Floor($targetBytes * $closeEnoughFactor)
    $inputFullPath = $InputItem.FullName
    $directory = $InputItem.DirectoryName
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputItem.Name)
    $outputPath = Join-Path $directory "$baseName-compressed.mp4"

    if ($InputItem.Length -le $targetBytes) {
        Copy-Item -LiteralPath $inputFullPath -Destination $outputPath -Force
        Write-CompressProgressBar 100
        Write-Host
        Write-Host "Compressed into $([System.IO.Path]::GetFileName($outputPath))"
        return
    }

    $duration = Get-VideoDurationSeconds $inputFullPath
    if ($duration -le 0) {
        throw "Video duration is invalid."
    }

    $hasAudio = Test-HasAudio $inputFullPath
    $initialBudgetBytes = [long] [Math]::Floor($targetBytes * 0.992)
    $totalKbps = [int] [Math]::Floor(($initialBudgetBytes * 8 / $duration) / 1000)
    $audioKbps = Get-AudioBitrateKbps $hasAudio $totalKbps
    $minimumVideoKbps = if ($EncoderMode -eq "nvenc") { 16 } else { 32 }
    $videoKbps = [Math]::Max($minimumVideoKbps, $totalKbps - $audioKbps)
    $maxAttempts = 5
    $lowGoodKbps = $null
    $highBadKbps = $null
    $bestGoodPath = $null
    $bestGoodSize = 0L
    $bestEffortPath = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $candidatePath = Join-Path $directory ("$baseName-compressed.attempt-$attempt.mp4")
        Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue

        Invoke-EncodeAttempt $inputFullPath $candidatePath $videoKbps $audioKbps $hasAudio $duration $EncoderMode

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

        if ($bestEffortPath -and (Test-Path -LiteralPath $bestEffortPath)) {
            Remove-Item -LiteralPath $bestEffortPath -Force -ErrorAction SilentlyContinue
        }
        $bestEffortPath = $candidatePath

        $highBadKbps = $videoKbps

        if ($null -ne $lowGoodKbps) {
            $nextKbps = [int] [Math]::Floor(($lowGoodKbps + $highBadKbps) / 2)
        } else {
            $audioBytes = if ($hasAudio) { ($audioKbps * 1000 / 8) * $duration } else { 0 }
            $containerReserveBytes = [Math]::Max(128KB, $targetBytes * 0.02)
            $observedVideoBytes = [Math]::Max(1, $candidateSize - $audioBytes)
            $allowedVideoBytes = [Math]::Max(1, ($targetBytes * 0.985) - $audioBytes - $containerReserveBytes)
            $safety = if ($EncoderMode -eq "nvenc") { 0.97 } else { 0.985 }
            $nextKbps = [int] [Math]::Floor($videoKbps * ($allowedVideoBytes / [double] $observedVideoBytes) * $safety)
        }

        if ($nextKbps -ge $videoKbps) {
            $nextKbps = if ($EncoderMode -eq "nvenc") {
                [int] [Math]::Floor($videoKbps * 0.75)
            } else {
                $videoKbps - 16
            }
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
        if ($bestEffortPath -and (Test-Path -LiteralPath $bestEffortPath)) {
            Remove-Item -LiteralPath $bestEffortPath -Force -ErrorAction SilentlyContinue
        }

        $losslessPath = Join-Path $directory ("$baseName-compressed.lossless.mp4")
        Remove-Item -LiteralPath $losslessPath -Force -ErrorAction SilentlyContinue
        Invoke-LosslessCopy $inputFullPath $losslessPath $duration
        $bestGoodPath = $losslessPath
    }

    if (-not $bestGoodPath) {
        throw "Could not create a compressed output within $maxAttempts attempts."
    }

    Move-WithRetry $bestGoodPath $outputPath

    Get-ChildItem -LiteralPath $directory -Filter "$baseName-compressed.attempt-*.mp4" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-CompressProgressBar 100
    Write-Host
    Write-Host "Compressed into $([System.IO.Path]::GetFileName($outputPath))"
}

function Get-DirectoryVideos {
    param([System.IO.DirectoryInfo] $InputDirectory)

    return Get-ChildItem -LiteralPath $InputDirectory.FullName -Filter "*.mp4" -File |
        Where-Object {
            ($_.BaseName -notlike "*-compressed") -and
            ($_.Name -notlike "*-compressed.attempt-*.mp4")
        } |
        Sort-Object Name
}

try {
    $moduleRoot = Join-Path $PSScriptRoot "modules"
    Import-Module (Join-Path $moduleRoot "Common\Compress.Common.psm1") -Force -DisableNameChecking
    Import-Module (Join-Path $moduleRoot "Progress\Compress.Progress.psm1") -Force -DisableNameChecking
    Import-Module (Join-Path $moduleRoot "Probe\Compress.Probe.psm1") -Force -DisableNameChecking
    Import-Module (Join-Path $moduleRoot "Encoding\Compress.Encoding.psm1") -Force -DisableNameChecking
    Import-Module (Join-Path $moduleRoot "FileSystem\Compress.FileSystem.psm1") -Force -DisableNameChecking

    Require-Command "ffmpeg"
    Require-Command "ffprobe"

    $encoderMode = if ($Nvidia) { "nvenc" } else { "x264" }
    if ($encoderMode -eq "nvenc") {
        Require-FfmpegEncoder "h264_nvenc"
    }

    $inputItem = Get-Item -LiteralPath $Path

    if ($Directory) {
        if (-not $inputItem.PSIsContainer) {
            throw "Directory mode expects a directory path."
        }

        $videoItems = @(Get-DirectoryVideos $inputItem)
        if ($videoItems.Count -eq 0) {
            throw "No .mp4 files found in directory."
        }

        foreach ($videoItem in $videoItems) {
            Invoke-CompressVideo $videoItem $MaxMB $encoderMode
        }

        exit 0
    }

    if ($inputItem.PSIsContainer) {
        throw "Input path is a directory. Use compress -d <dir-path> to compress a directory."
    }

    Invoke-CompressVideo $inputItem $MaxMB $encoderMode
    exit 0
} catch {
    Write-Host
    Write-Error $_.Exception.Message
    exit 1
}
