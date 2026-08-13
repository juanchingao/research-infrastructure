[CmdletBinding()]
param(
    [string[]]$Models = @("qwen2.5-coder:3b", "qwen2.5-coder:7b"),
    [ValidateRange(1, 20)]
    [int]$Repetitions = 3,
    [string]$OutputDirectory,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$moduleRoot = Join-Path $scriptRoot "modules"

Import-Module (Join-Path $moduleRoot "Config.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "OpenStackCli.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Compute.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot "Network.psm1") -Force -DisableNameChecking

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

function Get-PropertyValue([object]$Object, [string[]]$Names) {
    foreach ($name in $Names) {
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) { return $Object[$name] }
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Get-PrivateIp([string]$ServerId, [string]$Network) {
    $output = & openstack port list --server $ServerId --network $Network -f value -c "Fixed IP Addresses" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "No se pudieron consultar los puertos privados: $($output | Out-String)" }
    foreach ($line in @($output)) {
        $text = [string]$line
        if ($text -match "ip_address['`"=: ]+([0-9]+(?:\.[0-9]+){3})") { return $matches[1] }
        if ($text -match "\b(192\.168\.[0-9]+\.[0-9]+)\b") { return $matches[1] }
    }
    throw "No se pudo resolver la IP privada de Ollama."
}

function Invoke-OllamaRequest([string]$RstudioUser, [string]$RstudioHost, [string]$Endpoint, [hashtable]$Body) {
    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $remote = "printf '%s' '$encoded' | base64 -d | docker exec -i research-rstudio curl -fsS --max-time 600 -H 'Content-Type: application/json' --data-binary @- '$Endpoint/api/generate'"
    $output = & ssh -o "BatchMode=yes" -o "ConnectTimeout=15" "${RstudioUser}@${RstudioHost}" $remote 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fallo la peticion desde RStudio: $($output | Out-String)" }
    return (($output -join "`n") | ConvertFrom-Json)
}

if ($Models.Count -eq 0) { throw "Debes indicar al menos un modelo." }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDirectory = Join-Path $repoRoot "artifacts\ollama-benchmark-$stamp"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$ollamaExample = Read-FlatConfig (Join-Path $repoRoot "config\ollama.example.yaml")
$localPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path $repoRoot "config\ollama.local.yaml" } else { $ConfigPath }
$ollamaLocal = Read-FlatConfig $localPath
foreach ($item in $ollamaLocal.GetEnumerator()) { $ollamaExample[$item.Key] = $item.Value }
$researchConfig = Get-ResearchConfig -RepoRoot $repoRoot

Write-Host "Validando autenticacion OpenStack..." -ForegroundColor Cyan
$null = Test-OpenStackAuth
Write-Host "Resolviendo RStudio y Ollama..." -ForegroundColor Cyan
$ollamaServer = Get-ResearchServerByName -Name $ollamaExample["instance_name"]
$rstudioServer = Get-ResearchServerByName -Name $researchConfig["instance_name"]
if ($null -eq $ollamaServer -or $null -eq $rstudioServer) { throw "Las instancias Ollama y RStudio deben existir." }

$ollamaId = [string](Get-PropertyValue $ollamaServer @("ID", "id"))
$rstudioId = [string](Get-PropertyValue $rstudioServer @("ID", "id"))
$ollamaIp = Get-PrivateIp -ServerId $ollamaId -Network $ollamaExample["network"]
$floatingIps = @(Get-ServerFloatingIps -ServerId $rstudioId)
if ($floatingIps.Count -eq 0) { throw "RStudio no tiene floating IP." }
$rstudioHost = [string](Get-PropertyValue $floatingIps[0] @("Floating IP Address", "floating_ip_address"))
$endpoint = "http://${ollamaIp}:11434"

$prompts = @(
    @{ Id = "transformacion"; Text = "Escribe una funcion en R que reciba un data.frame, elimine duplicados y devuelva las filas ordenadas por fecha. Usa dplyr y explica brevemente el codigo." },
    @{ Id = "correccion"; Text = "Corrige este codigo R y explica el error:`n`ndatos |>`n  group_by(grupo) |>`n  summarise(media = mean(valor))`n  arrange(desc(media))" },
    @{ Id = "modelado"; Text = "Crea una funcion en R que ajuste un modelo lineal por cada grupo de un data.frame usando tidyr::nest(), purrr::map() y broom::tidy(). Controla grupos con datos insuficientes y devuelve una tabla unificada." }
)

$results = [Collections.Generic.List[object]]::new()
foreach ($model in $Models) {
    Write-Host "Calentando $model..." -ForegroundColor Cyan
    $null = Invoke-OllamaRequest -RstudioUser $researchConfig["ssh_user"] -RstudioHost $rstudioHost -Endpoint $endpoint -Body @{
        model = $model; prompt = "Responde solamente: listo"; stream = $false; keep_alive = "15m"; options = @{ temperature = 0; num_predict = 8 }
    }

    foreach ($prompt in $prompts) {
        for ($run = 1; $run -le $Repetitions; $run++) {
            Write-Host "[$model] $($prompt.Id) $run/$Repetitions"
            $response = Invoke-OllamaRequest -RstudioUser $researchConfig["ssh_user"] -RstudioHost $rstudioHost -Endpoint $endpoint -Body @{
                model = $model; prompt = $prompt.Text; stream = $false; keep_alive = "15m"; options = @{ temperature = 0; seed = 42; num_predict = 512 }
            }
            $evalSeconds = [double]$response.eval_duration / 1000000000
            $results.Add([pscustomobject]@{
                model = $model
                prompt_id = $prompt.Id
                repetition = $run
                total_seconds = [math]::Round(([double]$response.total_duration / 1000000000), 3)
                load_seconds = [math]::Round(([double]$response.load_duration / 1000000000), 3)
                prompt_seconds = [math]::Round(([double]$response.prompt_eval_duration / 1000000000), 3)
                output_seconds = [math]::Round($evalSeconds, 3)
                prompt_tokens = [int]$response.prompt_eval_count
                output_tokens = [int]$response.eval_count
                tokens_per_second = if ($evalSeconds -gt 0) { [math]::Round(([double]$response.eval_count / $evalSeconds), 2) } else { 0 }
                done_reason = [string]$response.done_reason
                response = [string]$response.response
            })
        }
    }
}

$csvPath = Join-Path $OutputDirectory "results.csv"
$jsonPath = Join-Path $OutputDirectory "results.json"
$summaryPath = Join-Path $OutputDirectory "summary.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
$summary = $results | Group-Object model | ForEach-Object {
    [pscustomobject]@{
        model = $_.Name
        samples = $_.Count
        average_total_seconds = [math]::Round(($_.Group | Measure-Object total_seconds -Average).Average, 3)
        average_tokens_per_second = [math]::Round(($_.Group | Measure-Object tokens_per_second -Average).Average, 2)
        average_output_tokens = [math]::Round(($_.Group | Measure-Object output_tokens -Average).Average, 1)
    }
}
$summary | Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8

Write-Host ""
$summary | Format-Table -AutoSize
Write-Host "Resultados: $OutputDirectory" -ForegroundColor Green
