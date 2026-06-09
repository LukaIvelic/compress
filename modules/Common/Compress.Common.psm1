Set-StrictMode -Version Latest

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

Export-ModuleMember -Function Format-Size, Require-Command
