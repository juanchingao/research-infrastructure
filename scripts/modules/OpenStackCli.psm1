Set-StrictMode -Version Latest

function Invoke-OpenStack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [switch]$ExpectJson
    )

    $output = & openstack @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $fullCommand = "openstack " + ($Arguments -join " ")
        throw "Comando OpenStack fallo: $fullCommand`n$($output | Out-String)"
    }

    if (-not $ExpectJson) {
        return $output
    }

    $jsonText = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return $null
    }

    return $jsonText | ConvertFrom-Json
}

function Test-OpenStackAuth {
    [CmdletBinding()]
    param()

    $null = Invoke-OpenStack -Arguments @("token", "issue", "-f", "json") -ExpectJson
    return $true
}

Export-ModuleMember -Function Invoke-OpenStack, Test-OpenStackAuth

