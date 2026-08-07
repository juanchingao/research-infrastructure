Set-StrictMode -Version Latest


function Test-SshAvailable {
    [CmdletBinding()]
    param()

    $sshCommand = Get-Command ssh -ErrorAction SilentlyContinue

    if ($null -eq $sshCommand) {
        throw "No se encontró el comando ssh en este entorno."
    }

    return $true
}


function Test-ScpAvailable {
    [CmdletBinding()]
    param()

    $scpCommand = Get-Command scp -ErrorAction SilentlyContinue

    if ($null -eq $scpCommand) {
        throw "No se encontró el comando scp en este entorno."
    }

    return $true
}


function Invoke-ResearchSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [string]$Host
    )

    $null = Test-SshAvailable

    & ssh "$User@$Host"

    if ($LASTEXITCODE -ne 0) {
        throw "La sesión SSH terminó con código $LASTEXITCODE."
    }
}


function Invoke-ResearchSshCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [string]$Host,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $false)]
        [switch]$AllocateTty
    )

    $null = Test-SshAvailable

    if ($AllocateTty) {

        & ssh `
            -t `
            "$User@$Host" `
            $Command
    }
    else {

        & ssh `
            "$User@$Host" `
            $Command
    }

    if ($LASTEXITCODE -ne 0) {
        throw "El comando SSH remoto terminó con código $LASTEXITCODE."
    }
}


function Copy-ResearchFileToHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [string]$Host,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath
    )

    $null = Test-ScpAvailable

    if (-not (Test-Path -Path $LocalPath -PathType Leaf)) {
        throw "No existe el archivo local: $LocalPath"
    }

    $resolvedLocalPath = (Resolve-Path $LocalPath).Path

    & scp `
        $resolvedLocalPath `
        "${User}@${Host}:$RemotePath"

    if ($LASTEXITCODE -ne 0) {
        throw "La copia SCP terminó con código $LASTEXITCODE."
    }
}


function Invoke-ResearchSshTunnel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [string]$Host,

        [Parameter(Mandatory = $true)]
        [int]$LocalPort,

        [Parameter(Mandatory = $true)]
        [int]$RemotePort,

        [Parameter(Mandatory = $false)]
        [string]$RemoteHost = "127.0.0.1"
    )

    $null = Test-SshAvailable

    $forwardSpec = "127.0.0.1:${LocalPort}:${RemoteHost}:${RemotePort}"

    Write-Host ""
    Write-Host "Abriendo túnel SSH:"
    Write-Host "  localhost:$LocalPort -> $Host -> ${RemoteHost}:$RemotePort"
    Write-Host ""
    Write-Host "Mantén esta terminal abierta mientras uses el servicio."
    Write-Host "Pulsa Ctrl+C para cerrar el túnel."
    Write-Host ""

    & ssh `
        -N `
        -L $forwardSpec `
        -o "ExitOnForwardFailure=yes" `
        -o "ServerAliveInterval=60" `
        -o "ServerAliveCountMax=3" `
        "$User@$Host"

    if ($LASTEXITCODE -ne 0) {
        throw "El túnel SSH terminó con código $LASTEXITCODE."
    }
}


Export-ModuleMember -Function `
    Invoke-ResearchSsh, `
    Invoke-ResearchSshCommand, `
    Copy-ResearchFileToHost, `
    Invoke-ResearchSshTunnel