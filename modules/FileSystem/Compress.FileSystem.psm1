Set-StrictMode -Version Latest

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

Export-ModuleMember -Function Move-WithRetry
