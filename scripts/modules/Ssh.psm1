Set-StrictMode -Version Latest

function Invoke-ResearchSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [string]$Host
    )

    $sshCommand = Get-Command ssh -ErrorAction SilentlyContinue
    if ($null -eq $sshCommand) {
        throw "No se encontró el comando ssh en este entorno."
    }

    & ssh "$User@$Host"
}

Export-ModuleMember -Function Invoke-ResearchSsh

