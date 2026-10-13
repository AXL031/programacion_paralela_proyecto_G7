[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $taskRepo
try {
    & (Join-Path $PSScriptRoot 'init-env.ps1')
    docker compose build trainer master worker
    if ($LASTEXITCODE -ne 0) { throw 'No se pudieron compilar los servicios de entrenamiento.' }
    docker compose up -d --scale worker=2 --wait
    if ($LASTEXITCODE -ne 0) { throw 'Maestro y trabajadores no están disponibles.' }
    foreach ($taskMode in @('sequential', 'distributed')) {
        $taskOutput = docker compose --profile jobs run --rm trainer -mode $taskMode -config configs/training.json
        if ($LASTEXITCODE -ne 0) { throw ('Falló el entrenamiento ' + $taskMode) }
        $taskText = $taskOutput -join [Environment]::NewLine
        $taskResult = $taskText | ConvertFrom-Json
        [IO.File]::WriteAllText((Join-Path $taskRepo ('data/training-' + $taskMode + '.json')), $taskText)
        Write-Host ($taskMode + ': ' + $taskResult.run.run_id + ', estado ' + $taskResult.run.status)
    }
    $taskSequential = Get-Content -LiteralPath data/training-sequential.json -Raw | ConvertFrom-Json
    $taskDistributed = Get-Content -LiteralPath data/training-distributed.json -Raw | ConvertFrom-Json
    if ($taskSequential.artifact.snapshot_sha256 -ne $taskDistributed.artifact.snapshot_sha256) { throw 'Los entrenamientos usan snapshots diferentes.' }
    if ($taskSequential.artifact.weights.Count -ne $taskDistributed.artifact.weights.Count) { throw 'Las dimensiones del modelo difieren.' }
    $taskMaxDiff = 0.0
    for ($taskIndex = 0; $taskIndex -lt $taskSequential.artifact.weights.Count; $taskIndex++) {
        $taskMaxDiff = [Math]::Max($taskMaxDiff, [Math]::Abs($taskSequential.artifact.weights[$taskIndex] - $taskDistributed.artifact.weights[$taskIndex]))
    }
    if ($taskMaxDiff -gt 1e-9) { throw ('Los parámetros no son equivalentes: ' + $taskMaxDiff) }
    $taskReport = @{
        sequential_run = $taskSequential.run.run_id
        distributed_run = $taskDistributed.run.run_id
        max_weight_difference = $taskMaxDiff
        tolerance = 1e-9
        sequential_training_seconds = $taskSequential.run.training_seconds
        distributed_training_seconds = $taskDistributed.run.training_seconds
        workers = $taskDistributed.run.workers
        tasks_by_worker = $taskDistributed.run.tasks_by_worker
        test = $taskDistributed.artifact.evaluation.test
        measurement_scope = 'single functional verification; not a benchmark'
    }
    [IO.File]::WriteAllText((Join-Path $taskRepo 'data/training-comparison.json'), ($taskReport | ConvertTo-Json -Depth 6))
    Write-Host ('Máxima diferencia de parámetros: ' + $taskMaxDiff)
    Write-Host ('MAE modelo: ' + $taskReport.test.model.mae + '; baseline: ' + $taskReport.test.persistence_baseline.mae)
    Write-Host 'Resultados guardados en data/training-comparison.json.'
} finally { Pop-Location }
