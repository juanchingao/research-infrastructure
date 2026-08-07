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
Import-Module (Join-Path -Path $moduleRoot -ChildPath "Ssh.psm1") -Force -DisableNameChecking

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Get-CurrentServer {
    param([hashtable]$Config)
    return Get-ResearchServerByName -Name $Config["instance_name"]
}

function Get-PreferredFloatingIp {
    param([string]$ServerId)
    $ips = Get-ServerFloatingIps -ServerId $ServerId
    if ($ips.Count -eq 0) {
        return $null
    }
    return $ips[0]."Floating IP Address"
}

$config = Get-ResearchConfig -RepoRoot $repoRoot -LocalConfigPath $ConfigPath

Write-Section "Validando autenticación OpenStack"
$null = Test-OpenStackAuth
Write-Host "Autenticación OK."

switch ($Action) {
    "create" {
        Write-Section "Comprobando security group"
        $researchSg = if ($config.ContainsKey("research_security_group") -and -not [string]::IsNullOrWhiteSpace($config["research_security_group"])) {
            $config["research_security_group"]
        }
        else {
            "research-workstation"
        }

        $null = Ensure-ResearchSecurityGroup -Name $researchSg
        Write-Host "Security group de investigación creado/listo: $researchSg"
        Write-Host "Security group aplicado a la VM en esta iteración: $($config["bootstrap_security_group"])"

        $server = Get-CurrentServer -Config $config
        if ($null -eq $server) {
            Write-Section "Creando instancia"
            $created = New-ResearchServer -Config $config
            $serverId = $created.id
            if ([string]::IsNullOrWhiteSpace($serverId)) {
                $serverId = $created.ID
            }
            if ([string]::IsNullOrWhiteSpace($serverId)) {
                throw "No se pudo resolver el ID de la instancia recién creada."
            }
            Write-Host "Instancia creada: $($config["instance_name"]) ($serverId)"
        }
        else {
            $serverId = $server.ID
            Write-Host "La instancia ya existe: $($server.Name) ($serverId), estado $($server.Status)."
        }

        Write-Section "Asignando floating IP"
        $floatingIp = Ensure-ServerFloatingIp -ServerId $serverId -ExternalNetwork $config["external_network"]
        Write-Host "Floating IP activa: $floatingIp"

        Write-Section "Siguientes pasos sugeridos"
        Write-Host "1) Ver estado cloud-init:"
        Write-Host "   ssh $($config["ssh_user"])@$floatingIp 'cloud-init status --wait'"
        Write-Host "2) Verificar Docker:"
        Write-Host "   ssh $($config["ssh_user"])@$floatingIp 'docker version && docker compose version'"
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

        $details = Get-ResearchServerDetails -ServerId $server.ID
        $floatingIp = Get-PreferredFloatingIp -ServerId $server.ID

        Write-Host "Nombre: $($server.Name)"
        Write-Host "ID: $($server.ID)"
        Write-Host "Estado: $($server.Status)"
        Write-Host "Redes: $($details.addresses)"
        Write-Host "Floating IP: $floatingIp"
        Write-Host "Security Groups: $($details.security_groups)"
        break
    }

    "ssh" {
        Write-Section "Conectando por SSH"
        $server = Get-CurrentServer -Config $config
        if ($null -eq $server) {
            throw "No existe la instancia '$($config["instance_name"])'. Ejecuta create primero."
        }

        $floatingIp = Get-PreferredFloatingIp -ServerId $server.ID
        if ([string]::IsNullOrWhiteSpace($floatingIp)) {
            throw "La instancia no tiene floating IP asociada."
        }

        Invoke-ResearchSsh -User $config["ssh_user"] -Host $floatingIp
        break
    }

    "destroy" {
        Write-Section "Destruyendo instancia"
        $server = Get-CurrentServer -Config $config
        if ($null -eq $server) {
            Write-Host "No hay instancia para destruir."
            break
        }

        if (-not $Force) {
            $answer = Read-Host "Confirma destrucción de '$($server.Name)' escribiendo YES"
            if ($answer -ne "YES") {
                throw "Operación cancelada por el usuario."
            }
        }

        $deleteFip = if ($DeleteFloatingIp) {
            $true
        }
        else {
            Get-BooleanFromConfig -Value $config["floating_ip_delete_on_destroy"] -Default $false
        }

        Remove-ServerFloatingIps -ServerId $server.ID -DeleteAfterDetach $deleteFip
        Remove-ResearchServer -ServerId $server.ID
        Write-Host "Instancia destruida: $($server.Name)"
        if ($deleteFip) {
            Write-Host "Floating IPs asociadas eliminadas."
        }
        else {
            Write-Host "Floating IPs desasociadas y conservadas."
        }
        break
    }
}
