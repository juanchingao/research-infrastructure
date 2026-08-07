[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("create", "status", "ssh", "destroy")]
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

Import-Module (Join-Path -Path $moduleRoot -ChildPath "Config.psm1") -Force -DisableNameChecking
Import-Module (Join-Path -Path $moduleRoot -ChildPath "OpenStackCli.psm1") -Force -DisableNameChecking
Import-Module (Join-Path -Path $moduleRoot -ChildPath "Compute.psm1") -Force -DisableNameChecking
Import-Module (Join-Path -Path $moduleRoot -ChildPath "Security.psm1") -Force -DisableNameChecking
Import-Module (Join-Path -Path $moduleRoot -ChildPath "Network.psm1") -Force -DisableNameChecking
Import-Module (Join-Path -Path $moduleRoot -ChildPath "Storage.psm1") -Force -DisableNameChecking
Import-Module (Join-Path -Path $moduleRoot -ChildPath "Ssh.psm1") -Force -DisableNameChecking


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

            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
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
        -PropertyNames @("Floating IP Address", "floating_ip_address")
}


$config = Get-ResearchConfig `
    -RepoRoot $repoRoot `
    -LocalConfigPath $ConfigPath


Write-Section "Validando autenticación OpenStack"
$null = Test-OpenStackAuth
Write-Host "Autenticación OK."


switch ($Action) {

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

        Write-Host "Security group de investigación creado/listo: $researchSg"
        Write-Host "Security group aplicado a la VM en esta iteración: $($config["bootstrap_security_group"])"



        Write-Section "Comprobando instancia"

        $server = Get-CurrentServer -Config $config

        if ($null -eq $server) {

            Write-Section "Creando instancia"

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

            if ([string]::IsNullOrWhiteSpace([string]$serverId)) {
                throw "No se pudo resolver el ID de la instancia existente."
            }

            Write-Host "La instancia ya existe: $($server.Name) ($serverId), estado $($server.Status)."
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

        Write-Host "Volumen persistente listo: $($config["data_volume_name"]) ($volumeId)"

        $null = Ensure-ResearchVolumeAttached `
            -VolumeId $volumeId `
            -ServerId $serverId

        Write-Host "Volumen persistente asociado a la instancia."



        Write-Section "Asignando floating IP"

        $floatingIp = Ensure-ServerFloatingIp `
            -ServerId $serverId `
            -ExternalNetwork $config["external_network"]

        Write-Host "Floating IP activa: $floatingIp"



        Write-Section "Siguientes pasos sugeridos"

        Write-Host "1) Ver estado cloud-init:"
        Write-Host "   ssh $($config["ssh_user"])@$floatingIp 'cloud-init status --wait'"

        Write-Host "2) Verificar discos:"
        Write-Host "   ssh $($config["ssh_user"])@$floatingIp 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS'"

        Write-Host "3) Entrar por SSH:"
        Write-Host "   powershell -ExecutionPolicy Bypass -File .\scripts\research.ps1 ssh"

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

        if ([string]::IsNullOrWhiteSpace([string]$serverId)) {
            throw "No se pudo resolver el ID de la instancia."
        }

        $details = Get-ResearchServerDetails -ServerId $serverId
        $floatingIp = Get-PreferredFloatingIp -ServerId $serverId

        Write-Host "Nombre: $($server.Name)"
        Write-Host "ID: $serverId"
        Write-Host "Estado: $($server.Status)"
        Write-Host "Redes: $($details.addresses)"
        Write-Host "Floating IP: $floatingIp"
        Write-Host "Security Groups: $($details.security_groups)"

        if ($config.ContainsKey("data_volume_name")) {

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

                Write-Host "Volumen persistente: $($config["data_volume_name"])"
                Write-Host "Volumen ID: $volumeId"
                Write-Host "Volumen estado: $($volumeDetails.status)"
                Write-Host "Volumen tamaño: $($volumeDetails.size) GB"
                Write-Host "Volumen asociado a esta VM: $attached"
            }
        }

        break
    }



    "ssh" {

        Write-Section "Conectando por SSH"

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
            throw "La instancia no tiene floating IP asociada."
        }

        Invoke-ResearchSsh `
            -User $config["ssh_user"] `
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

        if ([string]::IsNullOrWhiteSpace([string]$serverId)) {
            throw "No se pudo resolver el ID de la instancia."
        }

        if (-not $Force) {

            $answer = Read-Host "Confirma destrucción de '$($server.Name)' escribiendo YES"

            if ($answer -ne "YES") {
                throw "Operación cancelada por el usuario."
            }
        }



        #
        # IMPORTANTE:
        # El volumen de datos es persistente.
        # Se desadjunta antes de eliminar la VM, pero NO se elimina.
        #
        if (
            $config.ContainsKey("data_volume_name") -and
            -not [string]::IsNullOrWhiteSpace($config["data_volume_name"])
        ) {

            Write-Section "Desasociando volumen persistente"

            $volume = Get-ResearchVolumeByName `
                -Name $config["data_volume_name"]

            if ($null -ne $volume) {

                $volumeId = Get-ObjectPropertyValue `
                    -Object $volume `
                    -PropertyNames @("ID", "id")

                if (-not [string]::IsNullOrWhiteSpace([string]$volumeId)) {

                    Remove-ResearchVolumeFromServer `
                        -VolumeId $volumeId `
                        -ServerId $serverId

                    Write-Host "Volumen persistente desasociado y conservado: $($config["data_volume_name"])"
                }
            }
            else {
                Write-Host "No existe volumen persistente para desasociar."
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

        if ($deleteFip) {
            Write-Host "Floating IPs asociadas eliminadas."
        }
        else {
            Write-Host "Floating IPs desasociadas y conservadas."
        }

        Write-Host "Volumen persistente conservado."

        break
    }
}