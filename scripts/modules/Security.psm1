Set-StrictMode -Version Latest

function Get-SecurityRuleProperty {
    param(
        [Parameter(Mandatory = $true)]$Rule,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Rule) {
        return $null
    }

    foreach ($name in $Names) {
        if ($Rule -is [System.Collections.IDictionary] -and $Rule.Contains($name)) {
            return $Rule[$name]
        }

        $property = $Rule.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function Ensure-ResearchSecurityGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $groups = Invoke-OpenStack -Arguments @(
        "security", "group", "list", "-f", "json"
    ) -ExpectJson

    $existing = @(
        $groups | Where-Object { $_.Name -eq $Name }
    )

    if ($existing.Count -gt 0) {
        return $existing[0]
    }

    return Invoke-OpenStack -Arguments @(
        "security", "group", "create",
        $Name,
        "--description",
        "Research workstation SG managed by research-infrastructure",
        "-f",
        "json"
    ) -ExpectJson
}

function Ensure-ResearchSshRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SecurityGroupId,
        [Parameter(Mandatory = $true)][string]$RemoteCidr
    )

    $rules = Invoke-OpenStack -Arguments @(
        "security", "group", "rule", "list", $SecurityGroupId, "-f", "json"
    ) -ExpectJson

    $matching = @($rules | Where-Object {
        $protocol = Get-SecurityRuleProperty -Rule $_ -Names @(
            'IP Protocol', 'Protocol', 'protocol'
        )
        $portRange = Get-SecurityRuleProperty -Rule $_ -Names @(
            'Port Range', 'port_range'
        )
        $portMin = Get-SecurityRuleProperty -Rule $_ -Names @(
            'Port Range Min', 'port_range_min'
        )
        $portMax = Get-SecurityRuleProperty -Rule $_ -Names @(
            'Port Range Max', 'port_range_max'
        )
        $remoteCidr = Get-SecurityRuleProperty -Rule $_ -Names @(
            'Remote IP Prefix', 'IP Range', 'remote_ip_prefix'
        )

        $isSshPort = [string]$portRange -in @('22:22', '22') -or
            ([string]$portMin -eq '22' -and [string]$portMax -eq '22')

        [string]$protocol -eq 'tcp' -and
        $isSshPort -and
        [string]$remoteCidr -eq $RemoteCidr
    })

    if ($matching.Count -gt 0) {
        return $matching[0]
    }

    return Invoke-OpenStack -Arguments @(
        "security", "group", "rule", "create",
        "--ingress", "--ethertype", "IPv4",
        "--protocol", "tcp", "--dst-port", "22",
        "--remote-ip", $RemoteCidr,
        $SecurityGroupId, "-f", "json"
    ) -ExpectJson
}

function Ensure-ResearchTcpRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SecurityGroupId,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$RemoteCidr
    )

    $rules = Invoke-OpenStack -Arguments @(
        "security", "group", "rule", "list", $SecurityGroupId, "-f", "json"
    ) -ExpectJson

    $matching = @($rules | Where-Object {
        $protocol = Get-SecurityRuleProperty -Rule $_ -Names @('IP Protocol', 'Protocol', 'protocol')
        $portRange = Get-SecurityRuleProperty -Rule $_ -Names @('Port Range', 'port_range')
        $portMin = Get-SecurityRuleProperty -Rule $_ -Names @('Port Range Min', 'port_range_min')
        $portMax = Get-SecurityRuleProperty -Rule $_ -Names @('Port Range Max', 'port_range_max')
        $remoteCidr = Get-SecurityRuleProperty -Rule $_ -Names @('Remote IP Prefix', 'IP Range', 'remote_ip_prefix')
        $isPort = [string]$portRange -in @("${Port}:${Port}", "$Port") -or
            ([string]$portMin -eq "$Port" -and [string]$portMax -eq "$Port")
        [string]$protocol -eq 'tcp' -and $isPort -and [string]$remoteCidr -eq $RemoteCidr
    })

    if ($matching.Count -gt 0) { return $matching[0] }

    return Invoke-OpenStack -Arguments @(
        "security", "group", "rule", "create",
        "--ingress", "--ethertype", "IPv4",
        "--protocol", "tcp", "--dst-port", "$Port",
        "--remote-ip", $RemoteCidr,
        $SecurityGroupId, "-f", "json"
    ) -ExpectJson
}

Export-ModuleMember -Function Ensure-ResearchSecurityGroup, Ensure-ResearchSshRule, Ensure-ResearchTcpRule
