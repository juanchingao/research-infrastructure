Set-StrictMode -Version Latest

$script:ResearchSshIdentityFile = $null


function Set-ResearchSshIdentityFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $script:ResearchSshIdentityFile = $null
        return
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expandedPath.StartsWith("~")) {
        $expandedPath = Join-Path $HOME $expandedPath.Substring(1).TrimStart("/", "\")
    }

    if (-not (Test-Path -LiteralPath $expandedPath -PathType Leaf)) {
        throw "No existe la clave privada SSH del perfil: $expandedPath"
    }

    $script:ResearchSshIdentityFile = (Resolve-Path -LiteralPath $expandedPath).Path
}


function Get-ResearchSshIdentityArguments {
    if ([string]::IsNullOrWhiteSpace($script:ResearchSshIdentityFile)) {
        return @()
    }

    return @("-i", $script:ResearchSshIdentityFile, "-o", "IdentitiesOnly=yes")
}


function Select-ResearchPublicKeyPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $false)]
        [string]$Path
    )

    $selectedPath = $Path
    if ([string]::IsNullOrWhiteSpace($selectedPath)) {
        Write-Host ""
        Write-Host "Clave publica que se autorizara:"
        Write-Host "  [1] Portatil URJC"
        Write-Host "  [2] Sobremesa URJC"
        $answer = (Read-Host "Selecciona 1 o 2").Trim()
        $suffix = switch ($answer) {
            "1" { "portatil_urjc" }
            "2" { "sobremesa_urjc" }
            default { throw "Seleccion de clave publica no valida: '$answer'." }
        }

        $identityKey = "${suffix}_ssh_private_key"
        $keypairKey = "${suffix}_keypair"
        $suggestedPath = $null
        if ($Config.ContainsKey($identityKey) -and -not [string]::IsNullOrWhiteSpace($Config[$identityKey])) {
            $suggestedPath = "$($Config[$identityKey]).pub"
        }
        elseif ($Config.ContainsKey($keypairKey) -and -not [string]::IsNullOrWhiteSpace($Config[$keypairKey])) {
            $suggestedPath = "%USERPROFILE%\.ssh\$($Config[$keypairKey]).pub"
        }

        $prompt = if ([string]::IsNullOrWhiteSpace($suggestedPath)) {
            "Ruta de la clave publica (.pub)"
        }
        else {
            "Ruta de la clave publica [.pub predeterminada: $suggestedPath]"
        }
        $enteredPath = (Read-Host $prompt).Trim()
        $selectedPath = if ([string]::IsNullOrWhiteSpace($enteredPath)) { $suggestedPath } else { $enteredPath }
    }

    if ([string]::IsNullOrWhiteSpace($selectedPath)) {
        throw "No se ha indicado ninguna clave publica."
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($selectedPath)
    if ($expandedPath.StartsWith("~")) {
        $expandedPath = Join-Path $HOME $expandedPath.Substring(1).TrimStart("/", "\")
    }
    if (-not (Test-Path -LiteralPath $expandedPath -PathType Leaf)) {
        throw "No existe la clave publica: $expandedPath"
    }

    return (Resolve-Path -LiteralPath $expandedPath).Path
}


function Add-ResearchAuthorizedKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Host,
        [Parameter(Mandatory = $true)][string]$PublicKeyPath
    )

    $publicKey = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
    if ($publicKey -notmatch "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))\s+[A-Za-z0-9+/=]+(?:\s+.*)?$") {
        throw "El archivo no contiene una clave publica SSH compatible."
    }

    $encodedPublicKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKey))
    # Do not expand the key into a shell argument: Windows OpenSSH can remove
    # the nested quotes and make grep interpret key fragments as file names.
    $remoteCommand = 'set -eu; mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; printf %s {0} | base64 -d > ~/.ssh/.research-key.tmp; if ! grep -qxF -f ~/.ssh/.research-key.tmp ~/.ssh/authorized_keys; then cat ~/.ssh/.research-key.tmp >> ~/.ssh/authorized_keys; printf ''\n'' >> ~/.ssh/authorized_keys; fi; rm -f ~/.ssh/.research-key.tmp; chmod 600 ~/.ssh/authorized_keys' -f $encodedPublicKey
    Invoke-ResearchSshCommand -User $User -Host $Host -Command $remoteCommand
}


function Test-SshAvailable {
    [CmdletBinding()]
    param()

    $sshCommand = Get-Command ssh -ErrorAction SilentlyContinue

    if ($null -eq $sshCommand) {
        throw "No se encontro el comando ssh en este entorno."
    }

    return $true
}


function Test-ScpAvailable {
    [CmdletBinding()]
    param()

    $scpCommand = Get-Command scp -ErrorAction SilentlyContinue

    if ($null -eq $scpCommand) {
        throw "No se encontro el comando scp en este entorno."
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

    $identityArguments = @(Get-ResearchSshIdentityArguments)
    & ssh @identityArguments "$User@$Host"

    if ($LASTEXITCODE -ne 0) {
        throw "La sesion SSH termino con codigo $LASTEXITCODE."
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

        $identityArguments = @(Get-ResearchSshIdentityArguments)
        & ssh @identityArguments `
            -t `
            "$User@$Host" `
            $Command
    }
    else {

        $identityArguments = @(Get-ResearchSshIdentityArguments)
        & ssh @identityArguments `
            "$User@$Host" `
            $Command
    }

    if ($LASTEXITCODE -ne 0) {
        throw "El comando SSH remoto termino con codigo $LASTEXITCODE."
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

    $identityArguments = @(Get-ResearchSshIdentityArguments)
    & scp @identityArguments `
        $resolvedLocalPath `
        "${User}@${Host}:$RemotePath"

    if ($LASTEXITCODE -ne 0) {
        throw "La copia SCP termino con codigo $LASTEXITCODE."
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
    Write-Host "Abriendo tunel SSH:"
    Write-Host "  localhost:$LocalPort -> $Host -> ${RemoteHost}:$RemotePort"
    Write-Host ""
    Write-Host "Manten esta terminal abierta mientras uses el servicio."
    Write-Host "Pulsa Ctrl+C para cerrar el tunel."
    Write-Host ""

    $identityArguments = @(Get-ResearchSshIdentityArguments)
    & ssh @identityArguments `
        -N `
        -L $forwardSpec `
        -o "ExitOnForwardFailure=yes" `
        -o "ServerAliveInterval=60" `
        -o "ServerAliveCountMax=3" `
        "$User@$Host"

    if ($LASTEXITCODE -ne 0) {
        throw "El tunel SSH termino con codigo $LASTEXITCODE."
    }
}


function Wait-ResearchRemoteHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [string]$Host,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $false)]
        [string]$RemoteHost = "127.0.0.1",

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60,

        [Parameter(Mandatory = $false)]
        [int]$PollIntervalSeconds = 3
    )

    if ($TimeoutSeconds -le 0) {
        throw "TimeoutSeconds debe ser mayor que cero."
    }

    if ($PollIntervalSeconds -le 0) {
        throw "PollIntervalSeconds debe ser mayor que cero."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $httpState = @(
            Invoke-ResearchSshCommand `
                -User $User `
                -Host $Host `
                -Command "if curl -fsS --max-time 5 -o /dev/null http://${RemoteHost}:${Port}; then echo READY; else echo NOT_READY; fi"
        )

        $httpStatus = [string]($httpState | Select-Object -Last 1)

        if ($httpStatus.Trim() -eq "READY") {
            return $true
        }

        if ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    } while ((Get-Date) -lt $deadline)

    throw "El servicio HTTP remoto no respondio en ${RemoteHost}:$Port tras $TimeoutSeconds segundos."
}


Export-ModuleMember -Function `
    Set-ResearchSshIdentityFile, `
    Select-ResearchPublicKeyPath, `
    Add-ResearchAuthorizedKey, `
    Invoke-ResearchSsh, `
    Invoke-ResearchSshCommand, `
    Copy-ResearchFileToHost, `
    Invoke-ResearchSshTunnel, `
    Wait-ResearchRemoteHttp
