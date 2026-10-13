[CmdletBinding()]
param([switch]$SkipDownload)
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $taskRepo
try {
    & (Join-Path $PSScriptRoot 'init-env.ps1')
    docker info --format '{{.ServerVersion}}'
    if ($LASTEXITCODE -ne 0) { throw 'Inicia Docker Desktop y espera que el motor esté listo.' }
    if (-not $SkipDownload) { & (Join-Path $PSScriptRoot 'download-data.ps1') }
    docker compose up -d --build --scale worker=2 --wait
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo levantar el entorno.' }
    docker compose build loader
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo compilar el cargador.' }
    $taskLoaderOutput = docker compose --profile jobs run --rm loader -config configs/demo.json
    if ($LASTEXITCODE -ne 0) { throw 'La carga falló; revisa el error antes de continuar.' }
    $taskLoadResult = ($taskLoaderOutput -join [Environment]::NewLine) | ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $taskRepo 'data/demo-load.json'), ($taskLoaderOutput -join [Environment]::NewLine))
    $taskResolvedConfig = (docker compose config --format json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo resolver la configuración de Compose.' }
    $taskPort = $taskResolvedConfig.services.api.ports[0].published
    . (Join-Path $PSScriptRoot 'session.ps1')
    $taskHeaders=Get-DemoAuthorization ('http://127.0.0.1:'+$taskPort)
    $taskReady = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $taskPort + '/health/ready')
    $taskDataset = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $taskPort + '/api/v1/datasets/current') -Headers $taskHeaders
    Write-Host ('Dataset listo: ' + $taskDataset.dataset_id)
    Write-Host ('Carga reutilizada: ' + $taskLoadResult.reused)
    Write-Host ('Registros persistidos: ' + $taskDataset.stats.persisted)
    Write-Host ('Ventanas: ' + $taskDataset.snapshot.windows + '; ejemplos: ' + $taskDataset.snapshot.examples)
} finally { Pop-Location }
