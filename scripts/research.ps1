[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
[ValidateSet(
    "start",
    "stop",
    "create",
    "status",
    "init-data",
    "mount-data",
    "configure-rstudio",
    "deploy-rstudio",
    "check-r",
    "snapshot-data",
    "backup-data",
    "authorize-key",
    "tunnel",
    "ssh",
    "destroy"
)]
[string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Ask", "PortatilURJC", "SobremesaURJC")]
    [string]$Client = "Ask",

    [Parameter(Mandatory = $false)]
    [string]$PublicKeyPath,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$DeleteFloatingIp,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Ask", "Start", "Skip")]
    [string]$Ollama = "Ask"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$moduleRoot = Join-Path -Path $scriptRoot -ChildPath "modules"
$ollamaScript = Join-Path -Path $scriptRoot -ChildPath "ollama.ps1"

Import-Module (Join-Path $moduleRoot "Config.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "OpenStackCli.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Compute.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Security.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Network.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Storage.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Ssh.psm1") -Force -DisableNameChecking


function Write-Section {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}


function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {

        $property = $Object.PSObject.Properties[$propertyName]

        if ($null -ne $property) {

            $value = $property.Value

            if (
                $null -ne $value -and
                -not [string]::IsNullOrWhiteSpace([string]$value)
            ) {
                return $value
            }
        }
    }

    return $null
}


function Get-CurrentServer {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    return Get-ResearchServerByName -Name $Config["instance_name"]
}


function Get-PreferredFloatingIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    $ips = @(Get-ServerFloatingIps -ServerId $ServerId)

    if ($ips.Count -eq 0) {
        return $null
    }

    return Get-ObjectPropertyValue `
        -Object $ips[0] `
        -PropertyNames @(
            "Floating IP Address",
            "floating_ip_address"
        )
}


function Get-VolumeAttachmentDevice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeId,

        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    $details = Get-ResearchVolumeDetails -VolumeId $VolumeId

    foreach ($attachment in @($details.attachments)) {

        if ($null -eq $attachment) {
            continue
        }

        $attachmentServer = Get-ObjectPropertyValue `
            -Object $attachment `
            -PropertyNames @("server_id", "serverId")

        if ([string]$attachmentServer -ne $ServerId) {
            continue
        }

        $device = Get-ObjectPropertyValue `
            -Object $attachment `
            -PropertyNames @("device", "Device")

        if (-not [string]::IsNullOrWhiteSpace([string]$device)) {
            return [string]$device
        }
    }

    return $null
}


function Find-RemoteLuksDevice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [string]$RemoteHost
    )

    $lines = @(
        Invoke-ResearchSshCommand `
            -User $User `
            -Host $RemoteHost `
            -Command "lsblk -pnro NAME,FSTYPE"
    )

    $candidates = @()

    foreach ($line in $lines) {

        $text = [string]$line

        if ($text -match "^\s*(\S+)\s+crypto_LUKS\s*$") {
            $candidates += $matches[1]
        }
    }

    if ($candidates.Count -eq 1) {
        return $candidates[0]
    }

    if ($candidates.Count -eq 0) {
        throw "No se ha encontrado ningun dispositivo LUKS en la VM."
    }

    throw "Se han encontrado varios dispositivos LUKS. No se puede seleccionar uno de forma segura."
}


function Select-ResearchClientProfile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$RequestedClient
    )

    $selected = $RequestedClient
    if ($selected -eq "Ask") {
        Write-Host ""
        Write-Host "Equipo desde el que estas trabajando:"
        Write-Host "  [1] Portatil URJC"
        Write-Host "  [2] Sobremesa URJC"
        $answer = (Read-Host "Selecciona 1 o 2").Trim()
        $selected = switch ($answer) {
            "1" { "PortatilURJC" }
            "2" { "SobremesaURJC" }
            default { throw "Seleccion de equipo no valida: '$answer'." }
        }
    }

    $suffix = if ($selected -eq "PortatilURJC") { "portatil_urjc" } else { "sobremesa_urjc" }
    $keypairKey = "${suffix}_keypair"
    $identityKey = "${suffix}_ssh_private_key"

    if ($Config.ContainsKey($keypairKey) -and -not [string]::IsNullOrWhiteSpace($Config[$keypairKey])) {
        $Config["keypair"] = $Config[$keypairKey]
    }

    if ($Config.ContainsKey($identityKey) -and -not [string]::IsNullOrWhiteSpace($Config[$identityKey])) {
        Set-ResearchSshIdentityFile -Path $Config[$identityKey]
    }
    else {
        Set-ResearchSshIdentityFile -Path $null
    }

    Write-Host "Perfil de cliente: $selected (keypair: $($Config['keypair']))"
    return $selected
}

function Stop-RemoteResearchServices {
    param([string]$User, [string]$RemoteHost)

    Invoke-ResearchSshCommand -User $User -Host $RemoteHost -Command `
        "if [ -f /home/$User/research-services/rstudio/compose.yaml ]; then if [ -f /data/.secrets/rstudio.env ]; then docker compose --env-file /data/.secrets/rstudio.env -f /home/$User/research-services/rstudio/compose.yaml down; else docker rm -f research-rstudio 2>/dev/null || true; fi; fi"
}

function Close-RemoteDataVolume {
    param([string]$User, [string]$RemoteHost, [string]$MountPoint, [string]$MapperName)

    Stop-RemoteResearchServices -User $User -RemoteHost $RemoteHost
    Invoke-ResearchSshCommand -User $User -Host $RemoteHost -Command `
        "sync; if mountpoint -q $MountPoint; then if sudo fuser -m $MountPoint; then echo 'Hay procesos usando $MountPoint.' >&2; exit 42; fi; sudo umount $MountPoint; fi; if [ -e /dev/mapper/$MapperName ]; then sudo cryptsetup close $MapperName; fi"
}


$config = Get-ResearchConfig `
    -RepoRoot $repoRoot `
    -LocalConfigPath $ConfigPath

$selectedClient = Select-ResearchClientProfile -Config $config -RequestedClient $Client

$sshUser = $config["ssh_user"]

$mapperName = if (
    $config.ContainsKey("data_mapper_name") -and
    -not [string]::IsNullOrWhiteSpace($config["data_mapper_name"])
) {
    $config["data_mapper_name"]
}
else {
    "research-data"
}

$mountPoint = $config["data_mount_point"]


Write-Section "Validando autenticacion OpenStack"
$null = Test-OpenStackAuth
Write-Host "Autenticacion OK."


switch ($Action) {
    "start" {

    Write-Section "Iniciando estacion de investigacion"

    Write-Host ""
    Write-Host "Paso 1/5 - Infraestructura OpenStack"
    Write-Host ""

    & $PSCommandPath `
        -Action "create" `
        -ConfigPath $ConfigPath `
        -Client $selectedClient

    if ($LASTEXITCODE -ne 0) {
        throw "Fallo la preparacion de la infraestructura."
    }


    Write-Host ""
    Write-Host "Paso 2/5 - Volumen de datos cifrado"
    Write-Host ""

    & $PSCommandPath `
        -Action "mount-data" `
        -ConfigPath $ConfigPath `
        -Client $selectedClient

    if ($LASTEXITCODE -ne 0) {
        throw "Fallo el montaje del volumen de datos."
    }


    Write-Host ""
    Write-Host "Paso 3/5 - RStudio Server"
    Write-Host ""

    & $PSCommandPath `
        -Action "deploy-rstudio" `
        -ConfigPath $ConfigPath `
        -Client $selectedClient

    if ($LASTEXITCODE -ne 0) {
        throw "Fallo el despliegue de RStudio."
    }

    Write-Host ""
    Write-Host "Paso 4/5 - Ollama"
    Write-Host ""

    $startOllama = $false
    switch ($Ollama) {
        "Start" { $startOllama = $true }
        "Skip" { $startOllama = $false }
        "Ask" {
            $answer = Read-Host "Arrancar la instancia Ollama? Puede generar costes [s/N]"
            $normalizedAnswer = ([string]$answer).Trim().ToLowerInvariant()
            $startOllama = $normalizedAnswer -in @("s", "si", "sí", "y", "yes")
        }
    }

    if ($startOllama) {
        & $ollamaScript -Action "start" -Client $selectedClient
        if ($LASTEXITCODE -ne 0) {
            throw "Fallo el arranque de Ollama."
        }
    }
    else {
        Write-Host "Ollama: omitido; su instancia no se ha iniciado."
    }


    Write-Section "Estacion preparada"

    Write-Host ""
    Write-Host "VM: lista"
    Write-Host "Datos: desbloqueados y montados"
    Write-Host "RStudio: desplegado"
    Write-Host ""
    Write-Host $(if ($startOllama) { "Ollama: desplegado" } else { "Ollama: omitido" })
    Write-Host "Paso 5/5 - Abriendo tunel"
    Write-Host "RStudio estara disponible en:"
    Write-Host ""
    Write-Host "    http://localhost:8787"
    Write-Host ""


    & $PSCommandPath `
        -Action "tunnel" `
        -ConfigPath $ConfigPath `
        -Client $selectedClient

    break
}
    "create" {

        Write-Section "Comprobando security group"

        $researchSg = if (
            $config.ContainsKey("research_security_group") -and
            -not [string]::IsNullOrWhiteSpace($config["research_security_group"])
        ) {
            $config["research_security_group"]
        }
        else {
            "research-workstation"
        }

        $securityGroup = Ensure-ResearchSecurityGroup -Name $researchSg
        $securityGroupId = Get-ObjectPropertyValue -Object $securityGroup -PropertyNames @("ID", "id")
        $null = Ensure-ResearchSshRule `
            -SecurityGroupId $securityGroupId `
            -RemoteCidr $config["research_ssh_cidr"]

        Write-Host "Security group listo: $researchSg (SSH desde $($config["research_ssh_cidr"]))"


        Write-Section "Comprobando instancia"

        $server = Get-CurrentServer -Config $config

        if ($null -eq $server) {

            $created = New-ResearchServer -Config $config

            $serverId = Get-ObjectPropertyValue `
                -Object $created `
                -PropertyNames @("id", "ID")

            if ([string]::IsNullOrWhiteSpace([string]$serverId)) {
                throw "No se pudo resolver el ID de la instancia recien creada."
            }

            Write-Host "Instancia creada: $($config["instance_name"]) ($serverId)"
        }
        else {

            $serverId = Get-ObjectPropertyValue `
                -Object $server `
                -PropertyNames @("ID", "id")

            Write-Host "La instancia ya existe: $($server.Name) ($serverId)"
        }


        Write-Section "Comprobando estado de la instancia"

        $null = Ensure-ResearchServerRunning -ServerId $serverId


        Set-ResearchServerSecurityGroup `
            -ServerId $serverId `
            -ResearchSecurityGroup $researchSg `
            -BootstrapSecurityGroup $config["bootstrap_security_group"]


        Write-Section "Preparando volumen persistente"

        $volume = Ensure-ResearchVolume `
            -Name $config["data_volume_name"] `
            -SizeGb ([int]$config["data_volume_size_gb"]) `
            -VolumeType $config["data_volume_type"] `
            -AvailabilityZone $config["data_volume_availability_zone"]

        $volumeId = Get-ObjectPropertyValue `
            -Object $volume `
            -PropertyNames @("id", "ID")

        if ([string]::IsNullOrWhiteSpace([string]$volumeId)) {
            throw "No se pudo resolver el ID del volumen persistente."
        }

        $null = Ensure-ResearchVolumeAttached `
            -VolumeId $volumeId `
            -ServerId $serverId

        Write-Host "Volumen persistente listo y asociado."


        Write-Section "Asignando floating IP"

        $floatingIp = Ensure-ServerFloatingIp `
            -ServerId $serverId `
            -ExternalNetwork $config["external_network"]

        Write-Host "Floating IP activa: $floatingIp"


        Write-Section "Siguiente paso"

        Write-Host "Para desbloquear y montar los datos:"
        Write-Host "   .\scripts\research.ps1 mount-data"

        break
    }


    "init-data" {
        Write-Section "Inicializacion destructiva del volumen de datos"

        $server = Get-CurrentServer -Config $config
        if ($null -eq $server) { throw "No existe la instancia. Ejecuta create primero." }
        $serverId = Get-ObjectPropertyValue -Object $server -PropertyNames @("ID", "id")
        $floatingIp = Get-PreferredFloatingIp -ServerId $serverId
        if ([string]::IsNullOrWhiteSpace($floatingIp)) { throw "La VM no tiene floating IP." }

        $volume = Get-ResearchVolumeByName -Name $config["data_volume_name"]
        if ($null -eq $volume) { throw "No existe el volumen configurado." }
        $volumeId = Get-ObjectPropertyValue -Object $volume -PropertyNames @("ID", "id")
        $null = Ensure-ResearchVolumeAttached -VolumeId $volumeId -ServerId $serverId
        $device = Get-VolumeAttachmentDevice -VolumeId $volumeId -ServerId $serverId
        if ([string]::IsNullOrWhiteSpace($device)) {
            throw "OpenStack no informo del dispositivo; se cancela para no formatear un disco ambiguo."
        }

        $deviceState = @(Invoke-ResearchSshCommand -User $sshUser -Host $floatingIp -Command "if sudo cryptsetup isLuks $device 2>/dev/null; then echo LUKS; elif sudo wipefs -n $device | grep -q .; then echo IN_USE; else echo BLANK; fi")
        $state = ([string]($deviceState | Select-Object -Last 1)).Trim()
        if ($state -eq "LUKS") { throw "El volumen ya contiene LUKS. Usa mount-data; no se ha modificado nada." }
        if ($state -ne "BLANK") { throw "El dispositivo contiene datos o un filesystem. Se cancela por seguridad." }

        $expected = "INITIALIZE $($config["data_volume_name"])"
        $answer = Read-Host "ESTA OPERACION BORRA EL VOLUMEN. Escribe exactamente: $expected"
        if ($answer -ne $expected) { throw "Inicializacion cancelada." }

        Invoke-ResearchSshCommand -User $sshUser -Host $floatingIp -AllocateTty -Command "sudo cryptsetup luksFormat --type luks2 $device"
        Invoke-ResearchSshCommand -User $sshUser -Host $floatingIp -AllocateTty -Command "sudo cryptsetup open $device $mapperName"
        Invoke-ResearchSshCommand -User $sshUser -Host $floatingIp -Command "sudo mkfs.ext4 -L research-data /dev/mapper/$mapperName && sudo mkdir -p $mountPoint && sudo mount /dev/mapper/$mapperName $mountPoint && sudo install -d -m 700 -o $sshUser -g $sshUser $mountPoint/.secrets && sudo install -d -m 700 -o 1000 -g 1000 $mountPoint/rstudio-home && sudo install -d -m 2775 -o 1000 -g 1000 $mountPoint/.cache/renv && sudo chown ${sshUser}:${sshUser} $mountPoint"

        Write-Host "Volumen LUKS2 inicializado y montado. Ejecuta configure-rstudio para crear el secreto."
        break
    }

    "authorize-key" {
        $resolvedPublicKeyPath = Select-ResearchPublicKeyPath -Config $config -Path $PublicKeyPath

        $server = Get-CurrentServer -Config $config
        if ($null -eq $server) { throw "No existe la instancia '$($config['instance_name'])'." }
        $serverId = Get-ObjectPropertyValue -Object $server -PropertyNames @("ID", "id")
        $floatingIp = Get-PreferredFloatingIp -ServerId $serverId
        if ([string]::IsNullOrWhiteSpace($floatingIp)) { throw "La instancia no tiene floating IP." }

        Add-ResearchAuthorizedKey -User $sshUser -Host $floatingIp -PublicKeyPath $resolvedPublicKeyPath
        Write-Host "Clave publica autorizada en '$($config['instance_name'])'."
        break
    }

    "mount-data" {

        Write-Section "Preparando acceso a datos"

        $server = Get-CurrentServer -Config $config

        if ($null -eq $server) {
            throw "No existe la instancia '$($config["instance_name"])'."
        }

        $serverId = Get-ObjectPropertyValue `
            -Object $server `
            -PropertyNames @("ID", "id")

        $floatingIp = Get-PreferredFloatingIp -ServerId $serverId

        if ([string]::IsNullOrWhiteSpace([string]$floatingIp)) {
            throw "La VM no tiene floating IP."
        }


        $volume = Get-ResearchVolumeByName `
            -Name $config["data_volume_name"]

        if ($null -eq $volume) {
            throw "No existe el volumen '$($config["data_volume_name"])'."
        }

        $volumeId = Get-ObjectPropertyValue `
            -Object $volume `
            -PropertyNames @("ID", "id")


        #
        # Si por algun motivo el volumen esta desadjuntado,
        # lo vuelve a asociar.
        #
        $null = Ensure-ResearchVolumeAttached `
            -VolumeId $volumeId `
            -ServerId $serverId


        Write-Section "Identificando dispositivo"

        $device = Get-VolumeAttachmentDevice `
            -VolumeId $volumeId `
            -ServerId $serverId

        if ([string]::IsNullOrWhiteSpace([string]$device)) {

            Write-Host "OpenStack no informo del dispositivo. Buscando LUKS dentro de la VM..."

            $device = Find-RemoteLuksDevice `
                -User $sshUser `
                -RemoteHost $floatingIp
        }

        Write-Host "Dispositivo de datos: $device"


        #
        # Proteccion: debe ser realmente LUKS.
        #
        $luksResult = @(
            Invoke-ResearchSshCommand `
                -User $sshUser `
                -Host $floatingIp `
                -Command "sudo cryptsetup isLuks $device && echo YES || echo NO"
        )

        $isLuks = [string]($luksResult | Select-Object -Last 1)

        if ($isLuks.Trim() -ne "YES") {
            throw "El dispositivo '$device' no contiene una cabecera LUKS valida. Se cancela por seguridad."
        }


        Write-Section "Comprobando cifrado LUKS"

        $mapperResult = @(
            Invoke-ResearchSshCommand `
                -User $sshUser `
                -Host $floatingIp `
                -Command "if [ -e /dev/mapper/$mapperName ]; then echo OPEN; else echo CLOSED; fi"
        )

        $mapperState = [string]($mapperResult | Select-Object -Last 1)

        if ($mapperState.Trim() -eq "CLOSED") {

            Write-Host "El volumen esta cifrado y cerrado."
            Write-Host "Introduce ahora la contrasena LUKS."

            Invoke-ResearchSshCommand `
                -User $sshUser `
                -Host $floatingIp `
                -Command "sudo cryptsetup open $device $mapperName" `
                -AllocateTty
        }
        else {
            Write-Host "LUKS ya estaba desbloqueado."
        }


        Write-Section "Montando $mountPoint"

        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "sudo mkdir -p $mountPoint"

        $mountResult = @(
            Invoke-ResearchSshCommand `
                -User $sshUser `
                -Host $floatingIp `
                -Command "if mountpoint -q $mountPoint; then echo MOUNTED; else echo UNMOUNTED; fi"
        )

        $mountState = [string]($mountResult | Select-Object -Last 1)

        if ($mountState.Trim() -eq "UNMOUNTED") {

            Invoke-ResearchSshCommand `
                -User $sshUser `
                -Host $floatingIp `
                -Command "sudo mount /dev/mapper/$mapperName $mountPoint"

            Write-Host "Volumen montado."
        }
        else {
            Write-Host "$mountPoint ya estaba montado."
        }


        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "sudo chown ${sshUser}:${sshUser} $mountPoint"


        Write-Section "Datos listos"

        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "findmnt $mountPoint && df -h $mountPoint"

        Write-Host ""
        Write-Host "Los datos persistentes estan disponibles en $mountPoint."

        break
    }

"configure-rstudio" {
    Write-Section "Configurando secreto de RStudio"
    $server = Get-CurrentServer -Config $config
    if ($null -eq $server) { throw "No existe la instancia." }
    $serverId = Get-ObjectPropertyValue -Object $server -PropertyNames @("ID", "id")
    $floatingIp = Get-PreferredFloatingIp -ServerId $serverId
    if ([string]::IsNullOrWhiteSpace($floatingIp)) { throw "La VM no tiene floating IP." }

    $mountState = @(Invoke-ResearchSshCommand -User $sshUser -Host $floatingIp -Command "if mountpoint -q $mountPoint; then echo READY; else echo NOT_READY; fi")
    if (([string]($mountState | Select-Object -Last 1)).Trim() -ne "READY") {
        throw "El volumen no esta montado. Ejecuta mount-data primero."
    }

    $secretCommand = "umask 077; mkdir -p $mountPoint/.secrets; printf 'Contrasena de RStudio: '; stty -echo; IFS= read -r RSTUDIO_PASSWORD; stty echo; printf '\n'; if [ -z `"`$RSTUDIO_PASSWORD`" ]; then echo 'La contrasena no puede estar vacia.' >&2; exit 2; fi; printf 'RSTUDIO_PASSWORD=%s\n' `"`$RSTUDIO_PASSWORD`" > $mountPoint/.secrets/rstudio.env; chmod 600 $mountPoint/.secrets/rstudio.env"
    Invoke-ResearchSshCommand -User $sshUser -Host $floatingIp -Command $secretCommand -AllocateTty
    Write-Host "Secreto creado con permisos 0600 dentro del volumen cifrado."
    break
}
    "stop" {
        Write-Section "Deteniendo estacion de investigacion"

        $server = Get-CurrentServer -Config $config
        if ($null -eq $server) {
            Write-Host "La instancia RStudio no existe; comprobando Ollama."
            & $ollamaScript -Action "stop" -Client $selectedClient
            if ($LASTEXITCODE -ne 0) { throw "Fallo el apagado de Ollama." }
            break
        }

        $serverId = Get-ObjectPropertyValue -Object $server -PropertyNames @("ID", "id")
        $details = Get-ResearchServerDetails -ServerId $serverId
        $status = [string](Get-ObjectPropertyValue -Object $details -PropertyNames @("status", "Status"))
        $status = $status.ToUpperInvariant()

        if ($status -eq "ACTIVE") {
            $floatingIp = Get-PreferredFloatingIp -ServerId $serverId
            if ([string]::IsNullOrWhiteSpace($floatingIp)) {
                throw "La instancia esta activa pero no tiene floating IP; no se puede cerrar /data de forma segura."
            }

            Write-Section "Cerrando servicios y volumen de datos"
            Close-RemoteDataVolume `
                -User $sshUser `
                -RemoteHost $floatingIp `
                -MountPoint $mountPoint `
                -MapperName $mapperName

            Write-Host "Servicios detenidos, filesystem desmontado y LUKS cerrado."
        }
        elseif ($status -notin @("SHUTOFF", "SHELVED", "SHELVED_OFFLOADED")) {
            throw "No se puede realizar un cierre seguro desde el estado '$status'."
        }

        Write-Section "Apagando instancia"
        $null = Stop-ResearchServer -ServerId $serverId

        Write-Section "Estacion detenida"
        Write-Host "VM: apagada"
        Write-Host "Volumen Cinder: conservado"
        Write-Host "Floating IP: conservada"

        Write-Section "Apagando Ollama"
        & $ollamaScript -Action "stop" -Client $selectedClient
        if ($LASTEXITCODE -ne 0) {
            throw "RStudio se apago, pero fallo el apagado de Ollama."
        }
        Write-Host "VM Ollama: apagada"
        Write-Host "Volumen de modelos: conservado"
        break
    }

"deploy-rstudio" {

    Write-Section "Desplegando RStudio"

    #
    # 1. Localizar la VM
    #
    $server = Get-CurrentServer -Config $config

    if ($null -eq $server) {
        throw "No existe la instancia '$($config["instance_name"])'. Ejecuta create primero."
    }

    $serverId = Get-ObjectPropertyValue `
        -Object $server `
        -PropertyNames @("ID", "id")

    if ([string]::IsNullOrWhiteSpace([string]$serverId)) {
        throw "No se pudo resolver el ID de la instancia."
    }

    $floatingIp = Get-PreferredFloatingIp -ServerId $serverId

    if ([string]::IsNullOrWhiteSpace([string]$floatingIp)) {
        throw "La instancia no tiene floating IP."
    }


    #
    # 2. Comprobar que /data esta desbloqueado y montado
    #
    Write-Section "Comprobando volumen de datos"

    $dataState = @(
        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "if mountpoint -q $mountPoint; then echo READY; else echo NOT_READY; fi"
    )

    $dataStatus = [string]($dataState | Select-Object -Last 1)

    if ($dataStatus.Trim() -ne "READY") {
        throw "El volumen de datos no esta montado. Ejecuta primero: .\scripts\research.ps1 mount-data"
    }

    Write-Host "$mountPoint esta montado."


    #
    # 3. Comprobar secreto de RStudio
    #
    $secretState = @(
        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "if [ -s /data/.secrets/rstudio.env ]; then echo READY; else echo MISSING; fi"
    )

    $secretStatus = [string]($secretState | Select-Object -Last 1)

    if ($secretStatus.Trim() -ne "READY") {
        throw "No existe /data/.secrets/rstudio.env o esta vacio."
    }

    Write-Host "Secreto de RStudio disponible."


    #
    # 4. Comprobar home persistente de RStudio
    #
    $homeState = @(
        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "if [ -d /data/rstudio-home ]; then echo READY; else echo MISSING; fi"
    )

    $homeStatus = [string]($homeState | Select-Object -Last 1)

    if ($homeStatus.Trim() -ne "READY") {
        throw "No existe /data/rstudio-home."
    }

    Write-Host "Home persistente de RStudio disponible."

    # The cache lives on the encrypted data volume and is never removed here.
    Invoke-ResearchSshCommand `
        -User $sshUser `
        -Host $floatingIp `
        -Command "sudo install -d -m 2775 -o 1000 -g 1000 /data/.cache/renv"

    Write-Host "Cache renv persistente disponible."


    #
    # 5. Localizar los archivos locales versionados
    #
    $localCompose = Join-Path `
        -Path $repoRoot `
        -ChildPath "services\rstudio\compose.yaml"

    $localDockerfile = Join-Path `
        -Path $repoRoot `
        -ChildPath "services\rstudio\Dockerfile"

    if (-not (Test-Path $localCompose -PathType Leaf)) {
        throw "No existe el compose de RStudio: $localCompose"
    }

    if (-not (Test-Path $localDockerfile -PathType Leaf)) {
        throw "No existe el Dockerfile de RStudio: $localDockerfile"
    }


    #
    # 6. Definir directorio remoto
    #
    $remoteDir = "/home/$sshUser/research-services/rstudio"
    $remoteCompose = "$remoteDir/compose.yaml"
    $remoteDockerfile = "$remoteDir/Dockerfile"


    #
    # 7. Crear directorio remoto
    #
    Write-Section "Sincronizando configuracion"

    Invoke-ResearchSshCommand `
        -User $sshUser `
        -Host $floatingIp `
        -Command "mkdir -p $remoteDir"


    #
    # 8. Copiar compose.yaml
    #
    Copy-ResearchFileToHost `
        -LocalPath $localCompose `
        -User $sshUser `
        -Host $floatingIp `
        -RemotePath $remoteCompose


    #
    # 9. Copiar Dockerfile
    #
    Copy-ResearchFileToHost `
        -LocalPath $localDockerfile `
        -User $sshUser `
        -Host $floatingIp `
        -RemotePath $remoteDockerfile

    Write-Host "compose.yaml y Dockerfile sincronizados."


    #
    # 10. Construir nuestra imagen y desplegar RStudio
    #
    Write-Section "Ejecutando Docker Compose"

    $composeCommand = `
        "docker compose " +
        "--env-file /data/.secrets/rstudio.env " +
        "-f $remoteCompose"

    Invoke-ResearchSshCommand `
        -User $sshUser `
        -Host $floatingIp `
        -Command "cd $remoteDir && $composeCommand build --pull && $composeCommand up -d"


    #
    # 11. Verificar que el contenedor esta en ejecucion
    #
    Write-Section "Verificando RStudio"

    $containerState = @(
        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "docker inspect -f '{{.State.Running}}' research-rstudio"
    )

    $running = [string]($containerState | Select-Object -Last 1)

    if ($running.Trim() -ne "true") {
        throw "El contenedor research-rstudio no esta ejecutandose correctamente."
    }

    Write-Host "Contenedor research-rstudio en ejecucion."

    #
    # 12. Verificar que RStudio responde en localhost:8787
    #
    $null = Wait-ResearchRemoteHttp `
        -User $sshUser `
        -Host $floatingIp `
        -Port 8787 `
        -TimeoutSeconds 90


    #
    # 13. Resultado
    #
    Write-Section "RStudio listo"

    Write-Host "Contenedor: research-rstudio"
    Write-Host "Imagen: research-rstudio:r4.6.0-rstudio2026.07.1-147"
    Write-Host "Puerto remoto: 127.0.0.1:8787"
    Write-Host ""
    Write-Host "Para acceder:"
    Write-Host "   .\scripts\research.ps1 tunnel"

    break
}

"snapshot-data" {
    Write-Section "Creando snapshot offline de los datos"
    $server = Get-CurrentServer -Config $config
    if ($null -eq $server) { throw "No existe la instancia." }
    $serverId = Get-ObjectPropertyValue -Object $server -PropertyNames @("ID", "id")
    $floatingIp = Get-PreferredFloatingIp -ServerId $serverId
    if ([string]::IsNullOrWhiteSpace($floatingIp)) { throw "La VM no tiene floating IP." }
    $volume = Get-ResearchVolumeByName -Name $config["data_volume_name"]
    if ($null -eq $volume) { throw "No existe el volumen configurado." }
    $volumeId = Get-ObjectPropertyValue -Object $volume -PropertyNames @("ID", "id")

    Close-RemoteDataVolume -User $sshUser -RemoteHost $floatingIp -MountPoint $mountPoint -MapperName $mapperName
    Remove-ResearchVolumeFromServer -VolumeId $volumeId -ServerId $serverId
    try {
        $snapshotName = "$($config["data_volume_name"])-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $snapshot = New-ResearchVolumeSnapshot -VolumeId $volumeId -Name $snapshotName
        $snapshotId = Get-ObjectPropertyValue -Object $snapshot -PropertyNames @("ID", "id")
        Write-Host "Snapshot disponible: $snapshotName ($snapshotId)"
    }
    finally {
        $null = Ensure-ResearchVolumeAttached -VolumeId $volumeId -ServerId $serverId
    }

    Write-Host "El volumen se ha vuelto a adjuntar y permanece cerrado. Ejecuta mount-data y deploy-rstudio."
    break
}

"check-r" {
    Write-Section "Comprobacion ligera de R y repositorios"
    $server = Get-CurrentServer -Config $config
    if ($null -eq $server) { throw "No existe la instancia." }
    $serverId = Get-ObjectPropertyValue -Object $server -PropertyNames @("ID", "id")
    $floatingIp = Get-PreferredFloatingIp -ServerId $serverId
    if ([string]::IsNullOrWhiteSpace($floatingIp)) { throw "La VM no tiene floating IP." }

    $rCheck = @'
options(timeout = 30)
repos <- getOption("repos")
print(repos)
stopifnot(!identical(unname(repos[["CRAN"]]), "@CRAN@"))
stopifnot(capabilities("libcurl"))
stopifnot(identical(Sys.getenv("RENV_PATHS_CACHE"), "/data/.cache/renv"))
stopifnot(identical(tolower(Sys.getenv("RENV_CONFIG_PPM_ENABLED")), "false"))
stopifnot(requireNamespace("renv", quietly = TRUE))
tf <- tempfile(fileext = ".gz")
download.file("https://cloud.r-project.org/src/contrib/PACKAGES.gz", tf, method = "libcurl", quiet = TRUE)
stopifnot(file.info(tf)$size > 100000)
ap <- available.packages(repos = repos[["CRAN"]], method = "libcurl")
stopifnot(nrow(ap) > 1000, "digest" %in% rownames(ap))
cache_probe <- file.path(Sys.getenv("RENV_PATHS_CACHE"), paste0(".write-test-", Sys.getpid()))
stopifnot(file.create(cache_probe)); unlink(cache_probe)
lib <- tempfile("r-binary-check-"); dir.create(lib)
downloads <- download.packages("digest", destdir = tempdir(), repos = repos[["CRAN"]], quiet = TRUE)
stopifnot(nrow(downloads) == 1L, file.exists(downloads[1L, 2L]))
archive_members <- utils::untar(downloads[1L, 2L], list = TRUE)
stopifnot(any(grepl("/Meta/package[.]rds$", archive_members)))
install.packages("digest", lib = lib, repos = repos[["CRAN"]], quiet = FALSE)
stopifnot(requireNamespace("digest", lib.loc = lib, quietly = TRUE))
cat("\nOK: R, CRAN, Posit binaries, renv and persistent cache are operational.\n")
'@
    $encodedCheck = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rCheck))
    # Do not use --vanilla here: it disables Rprofile.site, which is where the
    # image configures the Posit Package Manager repository.
    Invoke-ResearchSshCommand -User $sshUser -Host $floatingIp -Command "echo $encodedCheck | base64 -d | docker exec -i --user rstudio research-rstudio Rscript -"
    break
}

"backup-data" {
    Write-Section "Creando backup offline de los datos"
    $server = Get-CurrentServer -Config $config
    if ($null -eq $server) { throw "No existe la instancia." }
    $serverId = Get-ObjectPropertyValue -Object $server -PropertyNames @("ID", "id")
    $floatingIp = Get-PreferredFloatingIp -ServerId $serverId
    if ([string]::IsNullOrWhiteSpace($floatingIp)) { throw "La VM no tiene floating IP." }
    $volume = Get-ResearchVolumeByName -Name $config["data_volume_name"]
    if ($null -eq $volume) { throw "No existe el volumen configurado." }
    $volumeId = Get-ObjectPropertyValue -Object $volume -PropertyNames @("ID", "id")

    Close-RemoteDataVolume -User $sshUser -RemoteHost $floatingIp -MountPoint $mountPoint -MapperName $mapperName
    Remove-ResearchVolumeFromServer -VolumeId $volumeId -ServerId $serverId
    try {
        $backupName = "$($config["data_volume_name"])-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $backup = New-ResearchVolumeBackup -VolumeId $volumeId -Name $backupName
        $backupId = Get-ObjectPropertyValue -Object $backup -PropertyNames @("ID", "id")
        Write-Host "Backup disponible: $backupName ($backupId)"
    }
    finally {
        $null = Ensure-ResearchVolumeAttached -VolumeId $volumeId -ServerId $serverId
    }

    Write-Host "El volumen se ha vuelto a adjuntar y permanece cerrado. Ejecuta mount-data y deploy-rstudio."
    break
}

"tunnel" {

    Write-Section "Preparando tunel RStudio"

    $server = Get-CurrentServer -Config $config

    if ($null -eq $server) {
        throw "No existe la instancia '$($config["instance_name"])'."
    }

    $serverId = Get-ObjectPropertyValue `
        -Object $server `
        -PropertyNames @("ID", "id")

    if ([string]::IsNullOrWhiteSpace([string]$serverId)) {
        throw "No se pudo resolver el ID de la instancia."
    }

    $floatingIp = Get-PreferredFloatingIp -ServerId $serverId

    if ([string]::IsNullOrWhiteSpace([string]$floatingIp)) {
        throw "La instancia no tiene floating IP."
    }


    #
    # Verificar primero que RStudio responde.
    #
    try {
        $null = Wait-ResearchRemoteHttp `
            -User $sshUser `
            -Host $floatingIp `
            -Port 8787 `
            -TimeoutSeconds 30
    }
    catch {
        throw "RStudio no esta disponible. Ejecuta primero: .\scripts\research.ps1 deploy-rstudio. Detalle: $($_.Exception.Message)"
    }


    Write-Host ""
    Write-Host "RStudio disponible."
    Write-Host "Abriendo acceso en:"
    Write-Host ""
    Write-Host "    http://localhost:8787"
    Write-Host ""


    Invoke-ResearchSshTunnel `
        -User $sshUser `
        -Host $floatingIp `
        -LocalPort 8787 `
        -RemotePort 8787 `
        -RemoteHost "127.0.0.1"

    break
}

    "status" {

        Write-Section "Estado de la instancia"

        $server = Get-CurrentServer -Config $config

        if ($null -eq $server) {
            Write-Host "No existe la instancia '$($config["instance_name"])'."
            break
        }

        $serverId = Get-ObjectPropertyValue `
            -Object $server `
            -PropertyNames @("ID", "id")

        $details = Get-ResearchServerDetails -ServerId $serverId
        $floatingIp = Get-PreferredFloatingIp -ServerId $serverId

        Write-Host "Nombre: $($server.Name)"
        Write-Host "ID: $serverId"
        Write-Host "Estado: $($server.Status)"
        Write-Host "Redes: $($details.addresses)"
        Write-Host "Floating IP: $floatingIp"
        Write-Host "Security Groups: $($details.security_groups)"


        $volume = Get-ResearchVolumeByName `
            -Name $config["data_volume_name"]

        if ($null -eq $volume) {

            Write-Host "Volumen persistente: no creado"
        }
        else {

            $volumeId = Get-ObjectPropertyValue `
                -Object $volume `
                -PropertyNames @("ID", "id")

            $volumeDetails = Get-ResearchVolumeDetails `
                -VolumeId $volumeId

            $attached = Test-ResearchVolumeAttachedToServer `
                -VolumeId $volumeId `
                -ServerId $serverId

            Write-Host "Volumen: $($config["data_volume_name"])"
            Write-Host "Volumen ID: $volumeId"
            Write-Host "Volumen estado: $($volumeDetails.status)"
            Write-Host "Volumen tamano: $($volumeDetails.size) GB"
            Write-Host "Asociado a esta VM: $attached"
        }

        break
    }


    "ssh" {

        Write-Section "Conectando por SSH"

        $server = Get-CurrentServer -Config $config

        if ($null -eq $server) {
            throw "No existe la instancia '$($config["instance_name"])'."
        }

        $serverId = Get-ObjectPropertyValue `
            -Object $server `
            -PropertyNames @("ID", "id")

        $floatingIp = Get-PreferredFloatingIp -ServerId $serverId

        if ([string]::IsNullOrWhiteSpace([string]$floatingIp)) {
            throw "La instancia no tiene floating IP asociada."
        }

        Invoke-ResearchSsh `
            -User $sshUser `
            -Host $floatingIp

        break
    }


    "destroy" {

        Write-Section "Destruyendo instancia"

        $server = Get-CurrentServer -Config $config

        if ($null -eq $server) {
            Write-Host "No hay instancia para destruir."
            break
        }

        $serverId = Get-ObjectPropertyValue `
            -Object $server `
            -PropertyNames @("ID", "id")

        if (-not $Force) {

            $answer = Read-Host "Confirma destruccion de '$($server.Name)' escribiendo YES"

            if ($answer -ne "YES") {
                throw "Operacion cancelada."
            }
        }


        $floatingIp = Get-PreferredFloatingIp -ServerId $serverId

        $volume = Get-ResearchVolumeByName `
            -Name $config["data_volume_name"]

        if ($null -ne $volume) {

            $volumeId = Get-ObjectPropertyValue `
                -Object $volume `
                -PropertyNames @("ID", "id")

            $attached = Test-ResearchVolumeAttachedToServer `
                -VolumeId $volumeId `
                -ServerId $serverId

            if ($attached) {

                #
                # Primero hacemos el equivalente automatico de:
                #
                # umount /data
                # cryptsetup close research-data
                #
                # antes de desconectar el disco.
                #
                if ([string]::IsNullOrWhiteSpace([string]$floatingIp)) {
                    throw "No se puede desmontar el volumen de forma segura porque la VM no tiene floating IP."
                }

                Write-Section "Cerrando volumen de datos"

                Close-RemoteDataVolume `
                    -User $sshUser `
                    -RemoteHost $floatingIp `
                    -MountPoint $mountPoint `
                    -MapperName $mapperName

                Write-Host "Sistema de archivos desmontado y LUKS cerrado."


                Write-Section "Desasociando volumen persistente"

                Remove-ResearchVolumeFromServer `
                    -VolumeId $volumeId `
                    -ServerId $serverId

                Write-Host "Volumen persistente conservado."
            }
        }


        $deleteFip = if ($DeleteFloatingIp) {
            $true
        }
        else {
            Get-BooleanFromConfig `
                -Value $config["floating_ip_delete_on_destroy"] `
                -Default $false
        }


        Write-Section "Desasociando floating IP"

        Remove-ServerFloatingIps `
            -ServerId $serverId `
            -DeleteAfterDetach $deleteFip


        Write-Section "Eliminando instancia"

        Remove-ResearchServer -ServerId $serverId

        Write-Host "Instancia destruida: $($server.Name)"
        Write-Host "Volumen persistente conservado."

        break
    }
}
