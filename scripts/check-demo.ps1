[CmdletBinding()]
param([int]$Requests = 100)
$ErrorActionPreference = 'Stop'
if ($Requests -lt 10 -or $Requests -gt 1000) { throw 'Requests debe estar entre 10 y 1000.' }
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $taskRepo
try {
    $taskCompose = (docker compose config --format json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo resolver Compose.' }
    $taskBase = 'http://127.0.0.1:' + $taskCompose.services.web.ports[0].published
    . (Join-Path $PSScriptRoot 'session.ps1')
    $taskHeaders=Get-DemoAuthorization $taskBase
    $taskDataset = Invoke-RestMethod ($taskBase + '/api/v1/datasets/current') -Headers $taskHeaders
    $taskModel = Invoke-RestMethod ($taskBase + '/api/v1/models/current') -Headers $taskHeaders
    if (-not $taskModel.ready) { throw 'Todavía no hay un modelo publicado.' }
    # PowerShell 7 can deserialize ISO dates as DateTime; avoid culture-dependent re-parsing.
    $taskOrigins = if ($taskModel.last_origin -is [datetime]) { [datetimeoffset]$taskModel.last_origin } else { [datetimeoffset]::Parse($taskModel.last_origin, [Globalization.CultureInfo]::InvariantCulture) }
    $taskLatencies = @()
    $taskHits = 0
    foreach ($taskPass in @(1, 2)) {
        $taskPassTimes = @()
        for ($taskIndex = 0; $taskIndex -lt $Requests; $taskIndex++) {
            $taskBody = @{
                dataset_id = $taskDataset.dataset_id
                zone_id = $taskDataset.zones[$taskIndex % $taskDataset.zones.Count].id
                forecast_origin = $taskOrigins.AddMinutes(-15 * [Math]::Floor($taskIndex / $taskDataset.zones.Count)).ToString('o')
                horizon_minutes = $taskDataset.window_minutes
            } | ConvertTo-Json
            $taskClock = [Diagnostics.Stopwatch]::StartNew()
            $taskPrediction = Invoke-RestMethod ($taskBase + '/api/v1/predictions') -Method Post -ContentType 'application/json' -Body $taskBody -Headers $taskHeaders
            $taskClock.Stop()
            $taskPassTimes += $taskClock.Elapsed.TotalMilliseconds
            if ($taskPrediction.cache_hit) { $taskHits++ }
            if ($taskPrediction.model_version -ne $taskModel.version -or $taskPrediction.predicted_observed_trips -lt 0) { throw 'Predicción inválida o cambio de modelo durante la medición.' }
        }
        $taskSorted = @($taskPassTimes | Sort-Object)
        $taskLatencies += @{pass=$taskPass; p95_ms=$taskSorted[[Math]::Ceiling(0.95*$Requests)-1]; max_ms=$taskSorted[-1]}
    }
    $taskInvalid = @{dataset_id=$taskDataset.dataset_id; zone_id=161; forecast_origin='2024-01-04T01:01:00Z'; horizon_minutes=15} | ConvertTo-Json
    $taskStatus = 0
    try { Invoke-RestMethod ($taskBase + '/api/v1/predictions') -Method Post -ContentType 'application/json' -Body $taskInvalid -Headers $taskHeaders | Out-Null }
    catch { $taskStatus = [int]$_.Exception.Response.StatusCode }
    if ($taskStatus -ne 400) { throw ('La fecha fuera de intervalo debe devolver 400; devolvió ' + $taskStatus) }
    $taskReport = @{model_version=$taskModel.version; requests=2*$Requests; cache_hits=$taskHits; passes=$taskLatencies; invalid_origin_status=$taskStatus; scope='HTTP local por proxy web; secuencial; no benchmark de producción'}
    [IO.File]::WriteAllText((Join-Path $taskRepo 'data/api-check.json'), ($taskReport | ConvertTo-Json -Depth 8))
    $taskReport | ConvertTo-Json -Depth 8
} finally { Pop-Location }
