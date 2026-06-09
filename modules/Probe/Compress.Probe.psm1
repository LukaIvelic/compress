Set-StrictMode -Version Latest

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

Export-ModuleMember -Function Get-VideoDurationSeconds, Test-HasAudio
