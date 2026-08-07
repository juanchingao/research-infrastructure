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
        "Research workstation SG (mínimo privilegio pendiente de CIDR VPN)",
        "-f",
        "json"
    ) -ExpectJson
}