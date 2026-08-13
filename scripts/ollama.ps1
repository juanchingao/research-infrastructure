[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("validate", "start", "stop", "create", "init-data", "resize-data", "deploy", "pull-model", "check-rstudio", "status", "ssh", "destroy")]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$Model
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$moduleRoot = Join-Path $scriptRoot "modules"

Import-Module (Join-Path $moduleRoot "Config.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "OpenStackCli.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Compute.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Security.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Network.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Storage.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Ssh.psm1") -Force -DisableNameChecking

function Write-Section([string]$Message) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Get-PropertyValue([object]$Object, [string[]]$Names) {
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
            $value = $Object[$name]
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
        }
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property.Value
        }
    }
    return $null
}

function Read-FlatConfig([string]$Path) {
    if (-not (Test-Path $Path -PathType Leaf)) { throw "No existe la configuracion: $Path" }
    $result = @{}
    foreach ($line in Get-Content $Path) {
        $text = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or $text.StartsWith("#")) { continue }
        if ($text -notmatch "^([A-Za-z0-9_]+)\s*:\s*(.*)$") { throw "Configuracion no valida en ${Path}: $line" }
        $result[$matches[1]] = $matches[2].Trim().Trim('"').Trim("'")
    }
    return $result
}

function Get-OllamaConfig {
    $example = Read-FlatConfig (Join-Path $repoRoot "config\ollama.example.yaml")
    $localPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        Join-Path $repoRoot "config\ollama.local.yaml"
    } else { $ConfigPath }
    $local = Read-FlatConfig $localPath
    foreach ($item in $local.GetEnumerator()) { $example[$item.Key] = $item.Value }

    $required = @(
        "instance_name", "image", "flavor", "network", "availability_zone", "external_network",
        "security_group", "ssh_user", "keypair", "ssh_cidr", "rstudio_private_cidr", "cloud_init_file",
        "data_volume_name", "data_volume_size_gb", "data_volume_type", "data_volume_availability_zone",
        "data_mount_point", "ollama_image", "ollama_model"
    )
    foreach ($key in $required) {
        if (-not $example.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($example[$key])) {
            throw "Falta clave requerida de Ollama: $key"
        }
    }
    foreach ($cidrKey in @("ssh_cidr", "rstudio_private_cidr")) {
        if ($example[$cidrKey] -notmatch "^.+/([0-9]|[12][0-9]|3[0-2])$") { throw "CIDR no valido: $cidrKey" }
    }
    $cloudInit = $example["cloud_init_file"]
    if (-not [IO.Path]::IsPathRooted($cloudInit)) { $cloudInit = Join-Path $repoRoot $cloudInit }
    $example["cloud_init_file"] = $cloudInit
    $example["research_security_group"] = $example["security_group"]
    $example["bootstrap_security_group"] = "default"
    return $example
}

function Get-Server { return Get-ResearchServerByName -Name $config["instance_name"] }

function Get-FloatingIp([string]$ServerId) {
    $ips = @(Get-ServerFloatingIps -ServerId $ServerId)
    if ($ips.Count -eq 0) { return $null }
    return Get-PropertyValue $ips[0] @("Floating IP Address", "floating_ip_address")
}

function Get-PrivateIp([string]$ServerId) {
    $output = & openstack port list `
        --server $ServerId `
        --network $config["network"] `
        -f value `
        -c "Fixed IP Addresses" 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudieron consultar los puertos privados de '$ServerId':`n$($output | Out-String)"
    }

    foreach ($line in @($output)) {
        $text = [string]$line
        if ($text -match 'ip_address[''":= ]+([0-9]+(?:\.[0-9]+){3})') { return $matches[1] }
        if ($text -match "\b(192\.168\.[0-9]+\.[0-9]+)\b") { return $matches[1] }
    }
    return $null
}

function Get-AttachmentDevice([string]$VolumeId, [string]$ServerId) {
    $volume = Get-ResearchVolumeDetails -VolumeId $VolumeId
    foreach ($attachment in @($volume.attachments)) {
        if ($null -eq $attachment) { continue }
        $attachedServer = Get-PropertyValue $attachment @("server_id", "serverId")
        if ([string]$attachedServer -ne $ServerId) { continue }
        return Get-PropertyValue $attachment @("device", "Device")
    }
    return $null
}

function Ensure-OllamaIngressRule([string]$SecurityGroup, [int]$Port, [string]$RemoteCidr, [string]$Description) {
    $previousErrorPreference = $ErrorActionPreference
    $output = @()
    $exitCode = -1
    try {
        $ErrorActionPreference = "Continue"
        $output = & openstack security group rule create `
            --ingress `
            --ethertype IPv4 `
            --protocol tcp `
            --dst-port $Port `
            --remote-ip $RemoteCidr `
            --description $Description `
            $SecurityGroup `
            -f json 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }

    if ($exitCode -eq 0) { return }

    $message = ($output | Out-String)
    if ($message -match '(?is)already\s+exists|duplicate|SecurityGroupRuleExists') {
        return
    }

    throw "No se pudo garantizar TCP/$Port desde $RemoteCidr en '$SecurityGroup':`n$message"
}

function Get-Context {
    $server = Get-Server
    if ($null -eq $server) { throw "No existe $($config['instance_name']). Ejecuta create." }
    $serverId = [string](Get-PropertyValue $server @("ID", "id"))
    $floatingIp = Get-FloatingIp $serverId
    if ([string]::IsNullOrWhiteSpace($floatingIp)) { throw "La instancia Ollama no tiene floating IP." }
    return @{ Server = $server; ServerId = $serverId; FloatingIp = $floatingIp }
}

$config = Get-OllamaConfig
$sshUser = $config["ssh_user"]

Write-Section "Validando autenticacion OpenStack"
$null = Test-OpenStackAuth
Write-Host "Autenticacion OpenStack: OK"

switch ($Action) {
    "validate" {
        Write-Section "Validando configuracion Ollama"
        $null = Invoke-OpenStack -Arguments @("image", "show", $config["image"], "-f", "json") -ExpectJson
        Write-Host "Imagen $($config['image']): OK"
        $null = Invoke-OpenStack -Arguments @("flavor", "show", $config["flavor"], "-f", "json") -ExpectJson
        Write-Host "Flavor $($config['flavor']): OK"
        $null = Invoke-OpenStack -Arguments @("network", "show", $config["network"], "-f", "json") -ExpectJson
        Write-Host "Red privada $($config['network']): OK"
        $null = Invoke-OpenStack -Arguments @("network", "show", $config["external_network"], "-f", "json") -ExpectJson
        Write-Host "Red externa $($config['external_network']): OK"
        $null = Invoke-OpenStack -Arguments @("keypair", "show", $config["keypair"], "-f", "json") -ExpectJson
        Write-Host "Keypair $($config['keypair']): OK"

        if (-not (Test-Path $config["cloud_init_file"] -PathType Leaf)) {
            throw "No existe cloud-init: $($config['cloud_init_file'])"
        }
        if (-not (Test-Path (Join-Path $repoRoot "services\ollama\compose.yaml") -PathType Leaf)) {
            throw "No existe services/ollama/compose.yaml"
        }
        Write-Host "Archivos locales: OK"

        $researchConfig = Get-ResearchConfig -RepoRoot $repoRoot
        $researchServer = Get-ResearchServerByName -Name $researchConfig["instance_name"]
        if ($null -eq $researchServer) { throw "No existe la instancia RStudio '$($researchConfig['instance_name'])'." }
        $researchServerId = [string](Get-PropertyValue $researchServer @("ID", "id"))
        $researchPrivateIp = Get-PrivateIp $researchServerId
        if ([string]::IsNullOrWhiteSpace($researchPrivateIp)) { throw "No se pudo resolver la IP privada de RStudio." }
        $expectedRstudioCidr = "${researchPrivateIp}/32"
        if ($config["rstudio_private_cidr"] -ne $expectedRstudioCidr) {
            throw "rstudio_private_cidr=$($config['rstudio_private_cidr']), pero RStudio usa $expectedRstudioCidr."
        }
        Write-Host "Origen privado RStudio ${expectedRstudioCidr}: OK"
        Write-Host "Validacion previa de Ollama: OK"
        break
    }

    "create" {
        Write-Section "Preparando red de Ollama"
        $sg = Ensure-ResearchSecurityGroup -Name $config["security_group"]
        $null = $sg
        Ensure-OllamaIngressRule -SecurityGroup $config["security_group"] -Port 22 -RemoteCidr $config["ssh_cidr"] -Description "SSH administracion Ollama"
        Ensure-OllamaIngressRule -SecurityGroup $config["security_group"] -Port 11434 -RemoteCidr $config["rstudio_private_cidr"] -Description "Ollama desde RStudio"

        Write-Section "Preparando instancia Ollama"
        $server = Get-Server
        $serverWasCreated = $false
        if ($null -eq $server) {
            $server = New-ResearchServer -Config $config
            $serverId = [string](Get-PropertyValue $server @("ID", "id"))
            $serverWasCreated = $true
        } else {
            $serverId = [string](Get-PropertyValue $server @("ID", "id"))
        }
        $null = Ensure-ResearchServerRunning -ServerId $serverId
        Set-ResearchServerSecurityGroup -ServerId $serverId -ResearchSecurityGroup $config["security_group"] -BootstrapSecurityGroup "default"

        Write-Section "Preparando volumen Ollama"
        $volume = Ensure-ResearchVolume -Name $config["data_volume_name"] -SizeGb ([int]$config["data_volume_size_gb"]) -VolumeType $config["data_volume_type"] -AvailabilityZone $config["data_volume_availability_zone"]
        $volumeId = [string](Get-PropertyValue $volume @("ID", "id"))
        $null = Ensure-ResearchVolumeAttached -VolumeId $volumeId -ServerId $serverId

        Write-Section "Preparando acceso"
        $floatingIp = Ensure-ServerFloatingIp -ServerId $serverId -ExternalNetwork $config["external_network"]
        if ($serverWasCreated) {
            $sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
            if ($null -ne $sshKeygen) {
                & $sshKeygen.Source -R $floatingIp | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "No se pudo retirar la clave SSH anterior de $floatingIp." }
            }
        }
        Write-Host "Ollama: $($config['instance_name']) ($floatingIp)"
        Write-Host "Endpoint privado: http://$(Get-PrivateIp $serverId):11434"
        break
    }

    "init-data" {
        $context = Get-Context
        $volume = Get-ResearchVolumeByName -Name $config["data_volume_name"]
        if ($null -eq $volume) { throw "No existe el volumen Ollama." }
        $volumeId = [string](Get-PropertyValue $volume @("ID", "id"))
        $null = Ensure-ResearchVolumeAttached -VolumeId $volumeId -ServerId $context.ServerId
        $device = Get-AttachmentDevice -VolumeId $volumeId -ServerId $context.ServerId
        if ([string]::IsNullOrWhiteSpace($device)) { throw "OpenStack no informo del dispositivo; se cancela para no formatear un disco ambiguo." }

        Write-Section "Esperando cloud-init"
        Invoke-ResearchSshCommand -User $sshUser -Host $context.FloatingIp -Command "sudo cloud-init status --wait"

        $mountPoint = $config["data_mount_point"]
        $setupTemplate = @'
set -eu
device='__DEVICE__'
mountpoint='__MOUNTPOINT__'

sudo systemctl stop docker containerd || true

current_target=$(findmnt -nr -S "$device" -o TARGET || true)
if [ -n "$current_target" ] && [ "$current_target" != "$mountpoint" ]; then
  sudo umount "$current_target"
fi

if sudo blkid -p "$device" >/dev/null 2>&1; then
  fstype=$(sudo blkid -s TYPE -o value "$device" || true)
  if [ "$fstype" != ext4 ]; then
    echo "Unexpected filesystem: $fstype" >&2
    exit 3
  fi
else
  if sudo wipefs -n "$device" | grep -q .; then
    echo 'Device contains unknown signatures' >&2
    exit 4
  fi
  sudo mkfs.ext4 -L ollama-data "$device"
fi

uuid=$(sudo blkid -s UUID -o value "$device")
sudo mkdir -p "$mountpoint"
sudo sed -i "\|UUID=$uuid |d" /etc/fstab
echo "UUID=$uuid $mountpoint ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
if ! mountpoint -q "$mountpoint"; then
  sudo mount "$mountpoint"
fi

sudo mkdir -p "$mountpoint/docker" "$mountpoint/containerd"
for item in buildkit containers engine-id image network overlay2 plugins runtimes swarm tmp trust volumes; do
  if [ -e "$mountpoint/$item" ] && [ ! -e "$mountpoint/docker/$item" ]; then
    sudo mv "$mountpoint/$item" "$mountpoint/docker/"
  fi
done

sudo install -d -m 755 /etc/docker /etc/containerd
printf '%s\n' '{"data-root":"__MOUNTPOINT__/docker"}' | sudo tee /etc/docker/daemon.json >/dev/null
sudo containerd config default | sudo sed -E 's|^[[:space:]]*root[[:space:]]*=.*$|root = "__MOUNTPOINT__/containerd"|' | sudo tee /etc/containerd/config.toml >/dev/null
sudo grep -Fx 'root = "__MOUNTPOINT__/containerd"' /etc/containerd/config.toml >/dev/null

# Dedicated Ollama VM: discard only the incomplete layers left in the old root.
sudo find /var/lib/containerd -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

sudo systemctl start containerd docker
findmnt "$mountpoint"
df -h "$mountpoint" /
docker info --format 'DockerRootDir={{.DockerRootDir}}'
sudo grep -E '^root[[:space:]]*=' /etc/containerd/config.toml
'@
        $setup = $setupTemplate.Replace('__DEVICE__', $device).Replace('__MOUNTPOINT__', $mountPoint)
        $encodedSetup = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($setup))
        Invoke-ResearchSshCommand -User $sshUser -Host $context.FloatingIp -Command "echo $encodedSetup | base64 -d | bash"
        break
    }

    "resize-data" {
        $context = Get-Context
        $volume = Get-ResearchVolumeByName -Name $config["data_volume_name"]
        if ($null -eq $volume) { throw "No existe el volumen Ollama." }
        $volumeId = [string](Get-PropertyValue $volume @("ID", "id"))
        $details = Get-ResearchVolumeDetails -VolumeId $volumeId
        $currentSizeGb = [int](Get-PropertyValue $details @("size", "Size"))
        $targetSizeGb = [int]$config["data_volume_size_gb"]
        if ($targetSizeGb -lt $currentSizeGb) {
            throw "No se puede reducir el volumen de $currentSizeGb GB a $targetSizeGb GB."
        }

        $null = Ensure-ResearchVolumeAttached -VolumeId $volumeId -ServerId $context.ServerId
        $device = Get-AttachmentDevice -VolumeId $volumeId -ServerId $context.ServerId
        if ([string]::IsNullOrWhiteSpace($device)) { throw "OpenStack no informo del dispositivo del volumen Ollama." }

        if ($targetSizeGb -gt $currentSizeGb) {
            Write-Section "Ampliando volumen Cinder de $currentSizeGb GB a $targetSizeGb GB"
            $null = Invoke-OpenStack -Arguments @("volume", "set", "--size", "$targetSizeGb", $volumeId)
            $details = Wait-ResearchVolumeStatus -VolumeId $volumeId -ExpectedStatus @("in-use", "available") -TimeoutSeconds 600
            $reportedSizeGb = [int](Get-PropertyValue $details @("size", "Size"))
            if ($reportedSizeGb -lt $targetSizeGb) {
                throw "Cinder sigue informando $reportedSizeGb GB tras solicitar $targetSizeGb GB."
            }
        } else {
            Write-Host "Volumen Cinder: ya tiene $targetSizeGb GB"
        }

        $mountPoint = $config["data_mount_point"]
        $resizeTemplate = @'
set -eu
device='__DEVICE__'
mountpoint='__MOUNTPOINT__'
target_bytes=__TARGET_BYTES__

test -b "$device" || { echo "No existe el dispositivo $device" >&2; exit 21; }
mountpoint -q "$mountpoint" || { echo "$mountpoint no esta montado" >&2; exit 22; }
[ "$(findmnt -nr -T "$mountpoint" -o SOURCE)" = "$device" ] || {
  echo "$mountpoint no esta montado desde $device" >&2
  exit 23
}

block=$(basename "$(readlink -f "$device")")
if [ -e "/sys/class/block/$block/device/rescan" ]; then
  echo 1 | sudo tee "/sys/class/block/$block/device/rescan" >/dev/null
elif command -v nvme >/dev/null 2>&1 && [[ "$block" = nvme* ]]; then
  sudo nvme ns-rescan "$device"
else
  for scan in /sys/class/scsi_host/host*/scan; do
    [ -e "$scan" ] || continue
    echo '- - -' | sudo tee "$scan" >/dev/null
  done
fi
sudo udevadm settle
actual_bytes=$(sudo blockdev --getsize64 "$device")
if [ "$actual_bytes" -lt "$target_bytes" ]; then
  echo "El kernel ve $actual_bytes bytes, menos de los $target_bytes esperados." >&2
  echo "OpenStack no ha propagado la nueva capacidad al attachment; apaga y arranca la VM y repite resize-data." >&2
  exit 24
fi

sudo resize2fs "$device"
findmnt "$mountpoint"
df -h "$mountpoint"
'@
        $targetBytes = [int64]$targetSizeGb * 1GB
        $resizeScript = $resizeTemplate.Replace("__DEVICE__", $device).Replace("__MOUNTPOINT__", $mountPoint).Replace("__TARGET_BYTES__", [string]$targetBytes)
        $encodedResize = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($resizeScript))
        Write-Section "Ampliando filesystem ext4"
        Invoke-ResearchSshCommand -User $sshUser -Host $context.FloatingIp -Command "echo $encodedResize | base64 -d | bash"
        Write-Host "Volumen Ollama ampliado a $targetSizeGb GB."
        break
    }

    "deploy" {
        $context = Get-Context
        $localCompose = Join-Path $repoRoot "services\ollama\compose.yaml"
        $remoteDir = "/home/$sshUser/research-services/ollama"
        Invoke-ResearchSshCommand -User $sshUser -Host $context.FloatingIp -Command "mkdir -p $remoteDir"
        Copy-ResearchFileToHost -LocalPath $localCompose -User $sshUser -Host $context.FloatingIp -RemotePath "$remoteDir/compose.yaml"
        $mountPoint = $config['data_mount_point']
        $preflightTemplate = @'
set -eu
mountpoint='__MOUNTPOINT__'
echo '--- Ollama storage preflight ---'
findmnt "$mountpoint" || { echo "ERROR: $mountpoint is not mounted" >&2; exit 11; }
docker_root=$(docker info --format '{{.DockerRootDir}}')
containerd_root=$(sudo grep -E '^[[:space:]]*root[[:space:]]*=' /etc/containerd/config.toml | head -1 | cut -d= -f2- | xargs)
echo "DockerRootDir=$docker_root"
echo "ContainerdRoot=$containerd_root"
df -h / "$mountpoint"
if [ "$docker_root" != "$mountpoint/docker" ]; then
  echo "ERROR: Docker still uses $docker_root" >&2
  exit 12
fi
if [ "$containerd_root" != "$mountpoint/containerd" ]; then
  echo "ERROR: containerd config uses $containerd_root" >&2
  exit 13
fi
'@
        $preflight = $preflightTemplate.Replace('__MOUNTPOINT__', $mountPoint)
        $encodedPreflight = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($preflight))
        Invoke-ResearchSshCommand -User $sshUser -Host $context.FloatingIp -Command "echo $encodedPreflight | base64 -d | bash"
        Invoke-ResearchSshCommand -User $sshUser -Host $context.FloatingIp -Command "cd $remoteDir && docker compose -f compose.yaml up -d"
        Invoke-ResearchSshCommand -User $sshUser -Host $context.FloatingIp -Command "curl -fsS --retry 20 --retry-connrefused --retry-delay 2 http://127.0.0.1:11434/api/version"
        break
    }

    "pull-model" {
        $context = Get-Context
        $modelToPull = if ([string]::IsNullOrWhiteSpace($Model)) { $config["ollama_model"] } else { $Model }
        if ($modelToPull -notmatch "^[A-Za-z0-9][A-Za-z0-9._/-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?$") {
            throw "Nombre de modelo Ollama no valido: $modelToPull"
        }
        Invoke-ResearchSshCommand -User $sshUser -Host $context.FloatingIp -Command "docker exec research-ollama ollama pull $modelToPull"
        break
    }

    "check-rstudio" {
        $server = Get-Server
        if ($null -eq $server) { throw "No existe la instancia Ollama." }
        $serverId = [string](Get-PropertyValue $server @("ID", "id"))
        $privateIp = Get-PrivateIp $serverId
        if ([string]::IsNullOrWhiteSpace($privateIp)) { throw "No se pudo resolver la IP privada de Ollama." }

        $researchConfig = Get-ResearchConfig -RepoRoot $repoRoot
        $researchServer = Get-ResearchServerByName -Name $researchConfig["instance_name"]
        if ($null -eq $researchServer) { throw "No existe la instancia RStudio." }
        $researchServerId = [string](Get-PropertyValue $researchServer @("ID", "id"))
        $researchFloatingIp = Get-FloatingIp $researchServerId
        if ([string]::IsNullOrWhiteSpace($researchFloatingIp)) { throw "RStudio no tiene floating IP." }

        Write-Section "Comprobando Ollama desde RStudio"
        $endpoint = "http://${privateIp}:11434"
        Invoke-ResearchSshCommand -User $researchConfig["ssh_user"] -Host $researchFloatingIp -Command "docker exec research-rstudio curl -fsS --max-time 15 $endpoint/api/version && echo && docker exec research-rstudio curl -fsS --max-time 15 $endpoint/api/tags"
        Write-Host "Endpoint validado desde RStudio: $endpoint"
        break
    }

    "start" {
        foreach ($step in @("validate", "create", "init-data", "deploy", "pull-model")) {
            try {
                & $PSCommandPath -Action $step -ConfigPath $ConfigPath
                if ($LASTEXITCODE -ne 0) { throw "Fallo ollama.ps1 $step" }
            }
            catch {
                Write-Error "Fallo en el paso '$step': $($_.Exception.Message)`n$($_.ScriptStackTrace)"
                throw
            }
        }
        Write-Section "Ollama listo"
        break
    }

    "stop" {
        $server = Get-Server
        if ($null -eq $server) { Write-Host "La instancia Ollama no existe."; break }
        $serverId = [string](Get-PropertyValue $server @("ID", "id"))
        $details = Get-ResearchServerDetails -ServerId $serverId
        $status = ([string](Get-PropertyValue $details @("status", "Status"))).ToUpperInvariant()
        if ($status -eq "ACTIVE") {
            $floatingIp = Get-FloatingIp $serverId
            if (-not [string]::IsNullOrWhiteSpace($floatingIp)) {
                Invoke-ResearchSshCommand -User $sshUser -Host $floatingIp -Command "if [ -f /home/$sshUser/research-services/ollama/compose.yaml ]; then docker compose -f /home/$sshUser/research-services/ollama/compose.yaml down; fi; sync"
            }
            $null = Stop-ResearchServer -ServerId $serverId
        }
        Write-Host "Ollama apagado; volumen y floating IP conservados."
        break
    }

    "status" {
        $server = Get-Server
        if ($null -eq $server) { Write-Host "Ollama: no creado"; break }
        $serverId = [string](Get-PropertyValue $server @("ID", "id"))
        $details = Get-ResearchServerDetails -ServerId $serverId
        Write-Host "VM: $($config['instance_name'])"
        Write-Host "Estado: $(Get-PropertyValue $details @('status', 'Status'))"
        Write-Host "Floating IP: $(Get-FloatingIp $serverId)"
        Write-Host "Endpoint privado: http://$(Get-PrivateIp $serverId):11434"
        Write-Host "Volumen: $($config['data_volume_name'])"
        break
    }

    "ssh" {
        $context = Get-Context
        Invoke-ResearchSsh -User $sshUser -Host $context.FloatingIp
        break
    }

    "destroy" {
        $server = Get-Server
        if ($null -eq $server) { Write-Host "La instancia Ollama no existe."; break }
        & $PSCommandPath -Action stop -ConfigPath $ConfigPath
        $server = Get-Server
        $serverId = [string](Get-PropertyValue $server @("ID", "id"))
        $volume = Get-ResearchVolumeByName -Name $config["data_volume_name"]
        if ($null -ne $volume) {
            $volumeId = [string](Get-PropertyValue $volume @("ID", "id"))
            $null = Remove-ResearchVolumeFromServer -VolumeId $volumeId -ServerId $serverId
        }
        Remove-ResearchServer -ServerId $serverId
        Write-Host "VM Ollama eliminada; volumen Cinder conservado."
        break
    }
}
