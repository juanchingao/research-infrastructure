Set-StrictMode -Version Latest

function Get-ResearchServerByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $servers = Invoke-OpenStack -Arguments @("server", "list", "--name", $Name, "--long", "-f", "json") -ExpectJson
    if ($null -eq $servers) {
        return $null
    }

    $exact = @($servers | Where-Object { $_.Name -eq $Name })
    if ($exact.Count -eq 0) {
        return $null
    }

    return $exact[0]
}

function New-ResearchServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    if (-not (Test-Path -Path $Config["cloud_init_file"] -PathType Leaf)) {
        throw "No existe cloud-init: $($Config["cloud_init_file"])"
    }

    $args = @(
        "server", "create",
        "--image", $Config["image"],
        "--flavor", $Config["flavor"],
        "--network", $Config["network"],
        "--security-group", $Config["research_security_group"],
        "--key-name", $Config["keypair"],
        "--availability-zone", $Config["availability_zone"],
        "--user-data", $Config["cloud_init_file"],
        "--wait",
        $Config["instance_name"],
        "-f", "json"
    )

    return Invoke-OpenStack -Arguments $args -ExpectJson
}

function Remove-ResearchServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    $null = Invoke-OpenStack -Arguments @("server", "delete", "--wait", $ServerId)
}

function Get-ResearchServerDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    return Invoke-OpenStack -Arguments @("server", "show", $ServerId, "-f", "json") -ExpectJson
}

function Wait-ResearchServerActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerId,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $details = Get-ResearchServerDetails -ServerId $ServerId
        $statusProperty = $details.PSObject.Properties['status']
        if ($null -eq $statusProperty) {
            throw "OpenStack no devolvio el estado de la instancia '$ServerId'."
        }

        $status = ([string]$statusProperty.Value).ToUpperInvariant()
        if ($status -eq 'ACTIVE') {
            return $details
        }
        if ($status -eq 'ERROR') {
            throw "La instancia '$ServerId' ha entrado en estado ERROR."
        }

        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "La instancia '$ServerId' no alcanzo el estado ACTIVE en $TimeoutSeconds segundos."
}

function Ensure-ResearchServerRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerId
    )

    $details = Get-ResearchServerDetails -ServerId $ServerId
    $statusProperty = $details.PSObject.Properties['status']
    if ($null -eq $statusProperty) {
        throw "OpenStack no devolvio el estado de la instancia '$ServerId'."
    }

    $status = ([string]$statusProperty.Value).ToUpperInvariant()
    switch ($status) {
        'ACTIVE' {
            Write-Host "La instancia ya esta activa."
            return $details
        }
        'SHUTOFF' {
            Write-Host "La instancia esta apagada; arrancandola."
            $null = Invoke-OpenStack -Arguments @('server', 'start', $ServerId)
        }
        'SHELVED' {
            Write-Host "La instancia esta shelved; recuperandola."
            $null = Invoke-OpenStack -Arguments @('server', 'unshelve', $ServerId)
        }
        'SHELVED_OFFLOADED' {
            Write-Host "La instancia esta shelved y descargada; recuperandola."
            $null = Invoke-OpenStack -Arguments @('server', 'unshelve', $ServerId)
        }
        'PAUSED' {
            Write-Host "La instancia esta pausada; reanudandola."
            $null = Invoke-OpenStack -Arguments @('server', 'unpause', $ServerId)
        }
        'SUSPENDED' {
            Write-Host "La instancia esta suspendida; reanudandola."
            $null = Invoke-OpenStack -Arguments @('server', 'resume', $ServerId)
        }
        'ERROR' {
            throw "La instancia '$ServerId' esta en estado ERROR."
        }
        default {
            Write-Host "La instancia esta en estado transitorio '$status'; esperando a ACTIVE."
        }
    }

    return Wait-ResearchServerActive -ServerId $ServerId
}

function Stop-ResearchServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerId,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 300
    )

    $details = Get-ResearchServerDetails -ServerId $ServerId
    $statusProperty = $details.PSObject.Properties['status']
    if ($null -eq $statusProperty) {
        throw "OpenStack no devolvio el estado de la instancia '$ServerId'."
    }

    $status = ([string]$statusProperty.Value).ToUpperInvariant()
    if ($status -eq 'SHUTOFF') {
        Write-Host "La instancia ya esta apagada."
        return $details
    }
    if ($status -in @('SHELVED', 'SHELVED_OFFLOADED')) {
        Write-Host "La instancia ya esta en estado $status y no consume computo activo."
        return $details
    }
    if ($status -ne 'ACTIVE') {
        throw "No se puede apagar de forma segura la instancia desde el estado '$status'."
    }

    Write-Host "Solicitando apagado de la instancia."
    $null = Invoke-OpenStack -Arguments @('server', 'stop', $ServerId)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $details = Get-ResearchServerDetails -ServerId $ServerId
        $statusProperty = $details.PSObject.Properties['status']
        if ($null -eq $statusProperty) {
            throw "OpenStack no devolvio el estado de la instancia '$ServerId'."
        }

        $status = ([string]$statusProperty.Value).ToUpperInvariant()
        if ($status -eq 'SHUTOFF') {
            return $details
        }
        if ($status -eq 'ERROR') {
            throw "La instancia '$ServerId' ha entrado en estado ERROR durante el apagado."
        }

        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "La instancia '$ServerId' no alcanzo el estado SHUTOFF en $TimeoutSeconds segundos."
}

function Set-ResearchServerSecurityGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerId,
        [Parameter(Mandatory = $true)][string]$ResearchSecurityGroup,
        [Parameter(Mandatory = $true)][string]$BootstrapSecurityGroup
    )

    $details = Get-ResearchServerDetails -ServerId $ServerId
    $currentNames = @($details.security_groups | ForEach-Object {
        if ($_ -is [string]) { $_ } else { $_.name }
    })

    if ($ResearchSecurityGroup -notin $currentNames) {
        $null = Invoke-OpenStack -Arguments @(
            "server", "add", "security", "group", $ServerId, $ResearchSecurityGroup
        )
    }

    if ($BootstrapSecurityGroup -ne $ResearchSecurityGroup -and $BootstrapSecurityGroup -in $currentNames) {
        $null = Invoke-OpenStack -Arguments @(
            "server", "remove", "security", "group", $ServerId, $BootstrapSecurityGroup
        )
    }
}

Export-ModuleMember -Function Get-ResearchServerByName, New-ResearchServer, Remove-ResearchServer, Get-ResearchServerDetails, Ensure-ResearchServerRunning, Stop-ResearchServer, Set-ResearchServerSecurityGroup
