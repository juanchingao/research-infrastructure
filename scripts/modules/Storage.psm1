Set-StrictMode -Version Latest


function Get-ResearchVolumeByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $volumes = Invoke-OpenStack -Arguments @(
        "volume",
        "list",
        "--name",
        $Name,
        "-f",
        "json"
    ) -ExpectJson

    if ($null -eq $volumes) {
        return $null
    }

    # Filtrado adicional para exigir coincidencia exacta de nombre.
    $matches = @(
        $volumes | Where-Object { $_.Name -eq $Name }
    )

    if ($matches.Count -eq 0) {
        return $null
    }

    if ($matches.Count -gt 1) {
        throw "Existe más de un volumen con el nombre '$Name'."
    }

    return $matches[0]
}


function Get-ResearchVolumeDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeId
    )

    return Invoke-OpenStack -Arguments @(
        "volume",
        "show",
        $VolumeId,
        "-f",
        "json"
    ) -ExpectJson
}


function Wait-ResearchVolumeStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeId,

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedStatus,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {

        $volume = Get-ResearchVolumeDetails -VolumeId $VolumeId
        $status = [string]$volume.status

        if ($status -in $ExpectedStatus) {
            return $volume
        }

        if ($status -in @("error", "error_deleting", "error_extending")) {
            throw "El volumen '$VolumeId' ha entrado en estado '$status'."
        }

        Start-Sleep -Seconds 3
    }

    throw "Timeout esperando al volumen '$VolumeId'. Estado esperado: $($ExpectedStatus -join ', ')."
}


function Ensure-ResearchVolume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$SizeGb,

        [Parameter(Mandatory = $true)]
        [string]$VolumeType,

        [Parameter(Mandatory = $true)]
        [string]$AvailabilityZone
    )

    $existing = Get-ResearchVolumeByName -Name $Name

    if ($null -ne $existing) {

        $volumeId = $existing.ID
        $details = Get-ResearchVolumeDetails -VolumeId $volumeId

        if ([int]$details.size -lt $SizeGb) {
            throw "El volumen '$Name' existe con $($details.size) GB, menor que los $SizeGb GB configurados."
        }

        return $details
    }

    $created = Invoke-OpenStack -Arguments @(
        "volume",
        "create",
        "--size",
        "$SizeGb",
        "--type",
        $VolumeType,
        "--availability-zone",
        $AvailabilityZone,
        "--description",
        "Persistent research data volume",
        "--non-bootable",
        $Name,
        "-f",
        "json"
    ) -ExpectJson

    $volumeId = $created.id

    if ([string]::IsNullOrWhiteSpace($volumeId)) {
        $volumeId = $created.ID
    }

    if ([string]::IsNullOrWhiteSpace($volumeId)) {
        throw "No se pudo resolver el ID del volumen recién creado."
    }

    return Wait-ResearchVolumeStatus `
        -VolumeId $volumeId `
        -ExpectedStatus @("available")
}


function Test-ResearchVolumeAttachedToServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeId,

        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    $details = Get-ResearchVolumeDetails -VolumeId $VolumeId

    foreach ($attachment in @($details.attachments)) {

        if ($null -eq $attachment) {
            continue
        }

        if ([string]$attachment.server_id -eq $ServerId) {
            return $true
        }
    }

    return $false
}


function Ensure-ResearchVolumeAttached {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeId,

        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    $details = Get-ResearchVolumeDetails -VolumeId $VolumeId

    if (Test-ResearchVolumeAttachedToServer `
        -VolumeId $VolumeId `
        -ServerId $ServerId) {

        return $details
    }

    $attachments = @($details.attachments)

    if ($attachments.Count -gt 0) {
        throw "El volumen '$VolumeId' ya está adjunto a otro servidor."
    }

    if ([string]$details.status -ne "available") {
        throw "El volumen '$VolumeId' no está disponible para adjuntar. Estado actual: $($details.status)"
    }

    $null = Invoke-OpenStack -Arguments @(
        "server",
        "add",
        "volume",
        $ServerId,
        $VolumeId
    )

    $deadline = (Get-Date).AddSeconds(180)

    while ((Get-Date) -lt $deadline) {

        if (Test-ResearchVolumeAttachedToServer `
            -VolumeId $VolumeId `
            -ServerId $ServerId) {

            return Get-ResearchVolumeDetails -VolumeId $VolumeId
        }

        Start-Sleep -Seconds 3
    }

    throw "Timeout esperando la asociación del volumen '$VolumeId' con el servidor '$ServerId'."
}


function Remove-ResearchVolumeFromServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeId,

        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    if (-not (Test-ResearchVolumeAttachedToServer `
        -VolumeId $VolumeId `
        -ServerId $ServerId)) {

        return
    }

    $null = Invoke-OpenStack -Arguments @(
        "server",
        "remove",
        "volume",
        $ServerId,
        $VolumeId
    )

    $null = Wait-ResearchVolumeStatus `
        -VolumeId $VolumeId `
        -ExpectedStatus @("available")
}


Export-ModuleMember -Function `
    Get-ResearchVolumeByName, `
    Get-ResearchVolumeDetails, `
    Ensure-ResearchVolume, `
    Ensure-ResearchVolumeAttached, `
    Test-ResearchVolumeAttachedToServer, `
    Remove-ResearchVolumeFromServer