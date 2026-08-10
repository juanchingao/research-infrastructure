Set-StrictMode -Version Latest

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
        [string]$_.'IP Protocol' -eq 'tcp' -and
        [string]$_.'Port Range' -in @('22:22', '22') -and
        [string]$_.'Remote IP Prefix' -eq $RemoteCidr
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

Export-ModuleMember -Function Ensure-ResearchSecurityGroup, Ensure-ResearchSshRule
