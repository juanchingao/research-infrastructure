Set-StrictMode -Version Latest

function Get-FlatYamlConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "No existe el archivo de configuración: $Path"
    }

    $result = @{}
    $lineNumber = 0

    foreach ($line in (Get-Content -Path $Path)) {
        $lineNumber += 1
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -notmatch "^([A-Za-z0-9_]+)\s*:\s*(.*)$") {
            throw "Formato YAML no soportado en ${Path}:$lineNumber. Usa pares simples key: value."
        }

        $key = $matches[1]
        $value = $matches[2].Trim()

        if (($value.StartsWith("'") -and $value.EndsWith("'")) -or ($value.StartsWith('"') -and $value.EndsWith('"'))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $result[$key] = $value
    }

    return $result
}

function Get-BooleanFromConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Value,

        [Parameter(Mandatory = $false)]
        [bool]$Default = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    $normalized = $Value.Trim().ToLowerInvariant()

    if ($normalized -in @("true", "1", "yes", "y", "on")) {
        return $true
    }

    if ($normalized -in @("false", "0", "no", "n", "off")) {
        return $false
    }

    throw "Valor booleano no válido: $Value"
}

function Get-ResearchConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $false)]
        [string]$LocalConfigPath
    )

    $examplePath = Join-Path -Path $RepoRoot -ChildPath "config\infrastructure.example.yaml"
    $localPath = if ([string]::IsNullOrWhiteSpace($LocalConfigPath)) {
        Join-Path -Path $RepoRoot -ChildPath "config\infrastructure.local.yaml"
    }
    else {
        $LocalConfigPath
    }

    $config = Get-FlatYamlConfig -Path $examplePath

    if (-not (Test-Path -Path $localPath -PathType Leaf)) {
        throw "Falta configuración local: $localPath. Copia config\infrastructure.local.example.yaml a config\infrastructure.local.yaml y personaliza."
    }

    $localOverrides = Get-FlatYamlConfig -Path $localPath
    foreach ($item in $localOverrides.GetEnumerator()) {
        $config[$item.Key] = $item.Value
    }

    $requiredKeys = @(
        "instance_name",
        "image",
        "flavor",
        "network",
        "availability_zone",
        "external_network",
        "bootstrap_security_group",
        "ssh_user",
        "keypair",
        "cloud_init_file"
    )

    foreach ($key in $requiredKeys) {
        if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($config[$key])) {
            throw "Falta clave requerida en configuración: $key"
        }
    }

    if ($config["keypair"] -eq "CHANGE_ME_OPENSTACK_KEYPAIR" -or $config["keypair"] -eq "REEMPLAZAR_POR_TU_KEYPAIR") {
        throw "Debes configurar un keypair válido en config\infrastructure.local.yaml."
    }

    $cloudInitPath = $config["cloud_init_file"]
    if (-not [System.IO.Path]::IsPathRooted($cloudInitPath)) {
        $cloudInitPath = Join-Path -Path $RepoRoot -ChildPath $cloudInitPath
    }
    $config["cloud_init_file"] = $cloudInitPath

    return $config
}

Export-ModuleMember -Function Get-ResearchConfig, Get-BooleanFromConfig
