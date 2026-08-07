Set-StrictMode -Version Latest

function Get-ServerFloatingIps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    # Una floating IP está asociada a un puerto de red, no directamente
    # al servidor. Primero obtenemos todos los puertos de la VM.
    $ports = Invoke-OpenStack -Arguments @(
        "port",
        "list",
        "--server",
        $ServerId,
        "-f",
        "json"
    ) -ExpectJson

    if ($null -eq $ports) {
        return @()
    }

    $result = @()

    # Buscar las floating IP asociadas a cada puerto de la VM.
    foreach ($port in @($ports)) {

        $portId = $port.ID

        if ([string]::IsNullOrWhiteSpace($portId)) {
            continue
        }

        $portFips = Invoke-OpenStack -Arguments @(
            "floating",
            "ip",
            "list",
            "--port",
            $portId,
            "-f",
            "json"
        ) -ExpectJson

        if ($null -ne $portFips) {
            $result += @($portFips)
        }
    }

    return @($result)
}


function Ensure-ServerFloatingIp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId,

        [Parameter(Mandatory = $true)]
        [string]$ExternalNetwork
    )

    # Si la VM ya tiene una floating IP, reutilizarla.
    $existing = @(Get-ServerFloatingIps -ServerId $ServerId)

    if ($existing.Count -gt 0) {
        return $existing[0]."Floating IP Address"
    }

    # Buscar una floating IP disponible en la red externa.
    $available = Invoke-OpenStack -Arguments @(
        "floating",
        "ip",
        "list",
        "--network",
        $ExternalNetwork,
        "--status",
        "DOWN",
        "-f",
        "json"
    ) -ExpectJson

    $ipAddress = $null

    if ($null -ne $available -and @($available).Count -gt 0) {

        $ipAddress = @($available)[0]."Floating IP Address"

    }
    else {

        # Si no hay ninguna disponible, crear una nueva.
        $created = Invoke-OpenStack -Arguments @(
            "floating",
            "ip",
            "create",
            $ExternalNetwork,
            "-f",
            "json"
        ) -ExpectJson

        $ipAddress = $created."floating_ip_address"

        if ([string]::IsNullOrWhiteSpace($ipAddress)) {
            $ipAddress = $created."Floating IP Address"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        throw "No se pudo obtener una floating IP."
    }

    # Asociar la floating IP a la VM.
    $null = Invoke-OpenStack -Arguments @(
        "server",
        "add",
        "floating",
        "ip",
        $ServerId,
        $ipAddress
    )

    return $ipAddress
}


function Remove-ServerFloatingIps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId,

        [Parameter(Mandatory = $false)]
        [bool]$DeleteAfterDetach = $false
    )

    $ips = @(Get-ServerFloatingIps -ServerId $ServerId)

    foreach ($item in $ips) {

        $ip = $item."Floating IP Address"

        if ([string]::IsNullOrWhiteSpace($ip)) {
            continue
        }

        # Desasociar floating IP de la VM.
        $null = Invoke-OpenStack -Arguments @(
            "server",
            "remove",
            "floating",
            "ip",
            $ServerId,
            $ip
        )

        # Opcionalmente eliminar también la floating IP del proyecto.
        if ($DeleteAfterDetach) {

            $id = $item.ID

            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $null = Invoke-OpenStack -Arguments @(
                    "floating",
                    "ip",
                    "delete",
                    $id
                )
            }
        }
    }
}


Export-ModuleMember -Function `
    Ensure-ServerFloatingIp, `
    Get-ServerFloatingIps, `
    Remove-ServerFloatingIps