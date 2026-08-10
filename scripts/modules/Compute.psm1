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

Export-ModuleMember -Function Get-ResearchServerByName, New-ResearchServer, Remove-ResearchServer, Get-ResearchServerDetails, Set-ResearchServerSecurityGroup
