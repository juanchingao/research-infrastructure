[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
[ValidateSet(
    "start",
    "create",
    "status",
    "mount-data",
    "deploy-rstudio",
    "tunnel",
    "ssh",
    "destroy"
)]
[string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$DeleteFloatingIp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$moduleRoot = Join-Path -Path $scriptRoot -ChildPath "modules"

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
        [string]$Host
    )

    $lines = @(
        Invoke-ResearchSshCommand `
            -User $User `
            -Host $Host `
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
        throw "No se ha encontrado ningún dispositivo LUKS en la VM."
    }

    throw "Se han encontrado varios dispositivos LUKS. No se puede seleccionar uno de forma segura."
}


$config = Get-ResearchConfig `
    -RepoRoot $repoRoot `
    -LocalConfigPath $ConfigPath

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


Write-Section "Validando autenticación OpenStack"
$null = Test-OpenStackAuth
Write-Host "Autenticación OK."


switch ($Action) {
    "start" {

    Write-Section "Iniciando estación de investigación"

    Write-Host ""
    Write-Host "Paso 1/4 - Infraestructura OpenStack"
    Write-Host ""

    & $PSCommandPath `
        -Action "create" `
        -ConfigPath $ConfigPath

    if ($LASTEXITCODE -ne 0) {
        throw "Falló la preparación de la infraestructura."
    }


    Write-Host ""
    Write-Host "Paso 2/4 - Volumen de datos cifrado"
    Write-Host ""

    & $PSCommandPath `
        -Action "mount-data" `
        -ConfigPath $ConfigPath

    if ($LASTEXITCODE -ne 0) {
        throw "Falló el montaje del volumen de datos."
    }


    Write-Host ""
    Write-Host "Paso 3/4 - RStudio Server"
    Write-Host ""

    & $PSCommandPath `
        -Action "deploy-rstudio" `
        -ConfigPath $ConfigPath

    if ($LASTEXITCODE -ne 0) {
        throw "Falló el despliegue de RStudio."
    }


    Write-Section "Estación preparada"

    Write-Host ""
    Write-Host "VM: lista"
    Write-Host "Datos: desbloqueados y montados"
    Write-Host "RStudio: desplegado"
    Write-Host ""
    Write-Host "Paso 4/4 - Abriendo túnel"
    Write-Host "RStudio estará disponible en:"
    Write-Host ""
    Write-Host "    http://localhost:8787"
    Write-Host ""


    & $PSCommandPath `
        -Action "tunnel" `
        -ConfigPath $ConfigPath

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

        $null = Ensure-ResearchSecurityGroup -Name $researchSg

        Write-Host "Security group listo: $researchSg"


        Write-Section "Comprobando instancia"

        $server = Get-CurrentServer -Config $config

        if ($null -eq $server) {

            $created = New-ResearchServer -Config $config

            $serverId = Get-ObjectPropertyValue `
                -Object $created `
                -PropertyNames @("id", "ID")

            if ([string]::IsNullOrWhiteSpace([string]$serverId)) {
                throw "No se pudo resolver el ID de la instancia recién creada."
            }

            Write-Host "Instancia creada: $($config["instance_name"]) ($serverId)"
        }
        else {

            $serverId = Get-ObjectPropertyValue `
                -Object $server `
                -PropertyNames @("ID", "id")

            Write-Host "La instancia ya existe: $($server.Name) ($serverId)"
        }


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
        # Si por algún motivo el volumen está desadjuntado,
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

            Write-Host "OpenStack no informó del dispositivo. Buscando LUKS dentro de la VM..."

            $device = Find-RemoteLuksDevice `
                -User $sshUser `
                -Host $floatingIp
        }

        Write-Host "Dispositivo de datos: $device"


        #
        # Protección: debe ser realmente LUKS.
        #
        $luksResult = @(
            Invoke-ResearchSshCommand `
                -User $sshUser `
                -Host $floatingIp `
                -Command "sudo cryptsetup isLuks $device && echo YES || echo NO"
        )

        $isLuks = [string]($luksResult | Select-Object -Last 1)

        if ($isLuks.Trim() -ne "YES") {
            throw "El dispositivo '$device' no contiene una cabecera LUKS válida. Se cancela por seguridad."
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

            Write-Host "El volumen está cifrado y cerrado."
            Write-Host "Introduce ahora la contraseña LUKS."

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
        Write-Host "Los datos persistentes están disponibles en $mountPoint."

        break
    }

"deploy-rstudio" {

    Write-Section "Desplegando RStudio"

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
    # Comprobar que /data está desbloqueado y montado.
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
        throw "El volumen de datos no está montado. Ejecuta primero: .\scripts\research.ps1 mount-data"
    }

    Write-Host "$mountPoint está montado."


    #
    # Comprobar secreto de RStudio.
    #
    $secretState = @(
        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "if [ -s /data/.secrets/rstudio.env ]; then echo READY; else echo MISSING; fi"
    )

    $secretStatus = [string]($secretState | Select-Object -Last 1)

    if ($secretStatus.Trim() -ne "READY") {
        throw "No existe /data/.secrets/rstudio.env o está vacío."
    }

    Write-Host "Secreto de RStudio disponible."


    #
    # Comprobar home persistente.
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


    #
    # Localizar compose.yaml del repositorio.
    #
    $localCompose = Join-Path `
        -Path $repoRoot `
        -ChildPath "services\rstudio\compose.yaml"

    if (-not (Test-Path $localCompose -PathType Leaf)) {
        throw "No existe el compose de RStudio: $localCompose"
    }


    #
    # Directorio de despliegue remoto.
    #
    $remoteDir = "/home/$sshUser/research-services/rstudio"
    $remoteCompose = "$remoteDir/compose.yaml"

    Write-Section "Sincronizando configuración"

    Invoke-ResearchSshCommand `
        -User $sshUser `
        -Host $floatingIp `
        -Command "mkdir -p $remoteDir"

    Copy-ResearchFileToHost `
        -LocalPath $localCompose `
        -User $sshUser `
        -Host $floatingIp `
        -RemotePath $remoteCompose

    Write-Host "compose.yaml sincronizado."


    #
    # Desplegar/recrear RStudio.
    #
    Write-Section "Ejecutando Docker Compose"

    $composeCommand = `
        "docker compose " +
        "--env-file /data/.secrets/rstudio.env " +
        "-f $remoteCompose"

    Invoke-ResearchSshCommand `
        -User $sshUser `
        -Host $floatingIp `
        -Command "$composeCommand pull && $composeCommand up -d"


    #
    # Verificar contenedor.
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
        throw "El contenedor research-rstudio no está ejecutándose correctamente."
    }


    #
    # Verificar servicio HTTP local.
    #
    $httpState = @(
        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "if curl -fsS -o /dev/null http://127.0.0.1:8787; then echo READY; else echo FAILED; fi"
    )

    $httpStatus = [string]($httpState | Select-Object -Last 1)

    if ($httpStatus.Trim() -ne "READY") {
        throw "RStudio está arrancado pero no responde en 127.0.0.1:8787."
    }


    Write-Section "RStudio listo"

    Write-Host "Contenedor: research-rstudio"
    Write-Host "Imagen: rocker/rstudio:4.6.0"
    Write-Host "Puerto remoto: 127.0.0.1:8787"
    Write-Host ""
    Write-Host "Para acceder:"
    Write-Host "   .\scripts\research.ps1 tunnel"

    break
}
"tunnel" {

    Write-Section "Preparando túnel RStudio"

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
    $serviceState = @(
        Invoke-ResearchSshCommand `
            -User $sshUser `
            -Host $floatingIp `
            -Command "if curl -fsS -o /dev/null http://127.0.0.1:8787; then echo READY; else echo NOT_READY; fi"
    )

    $serviceStatus = [string]($serviceState | Select-Object -Last 1)

    if ($serviceStatus.Trim() -ne "READY") {
        throw "RStudio no está disponible. Ejecuta primero: .\scripts\research.ps1 deploy-rstudio"
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
            Write-Host "Volumen tamaño: $($volumeDetails.size) GB"
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

            $answer = Read-Host "Confirma destrucción de '$($server.Name)' escribiendo YES"

            if ($answer -ne "YES") {
                throw "Operación cancelada."
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
                # Primero hacemos el equivalente automático de:
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

                Invoke-ResearchSshCommand `
                    -User $sshUser `
                    -Host $floatingIp `
                    -Command "if mountpoint -q $mountPoint; then sudo umount $mountPoint; fi; if [ -e /dev/mapper/$mapperName ]; then sudo cryptsetup close $mapperName; fi"

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