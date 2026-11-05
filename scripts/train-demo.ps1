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
    $taskSequentialDiagnostics = 'data/training-sequential-diagnostics.json'
    $taskDistributedDiagnostics = 'data/training-distributed-diagnostics.json'
    foreach ($taskMode in @('sequential', 'distributed')) {
        $taskArguments = @('--profile', 'jobs', 'run', '--rm', 'trainer', '-mode', $taskMode, '-config', 'configs/training.json')
        if ($taskMode -eq 'sequential') {
            $taskArguments += @('-diagnostics', $taskSequentialDiagnostics, '-sample-id', 'demo-sequential')
        } else {
            $taskArguments += @('-diagnostics', $taskDistributedDiagnostics, '-sample-id', 'demo-distributed', '-reference-diagnostics', $taskSequentialDiagnostics)
        }
        $taskOutput = docker compose @taskArguments
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
    if ($taskMaxDiff -gt 1e-9) { throw ('Los parámetros publicados no son equivalentes: ' + $taskMaxDiff) }
    if (-not $taskDistributed.diagnostics.equivalent) {
        throw ('Los candidatos SGD previos a selección no son equivalentes: ' + $taskDistributed.diagnostics.candidate_max_difference)
    }
    $taskReport = @{
        sequential_run = $taskSequential.run.run_id
        distributed_run = $taskDistributed.run.run_id
        max_weight_difference = $taskMaxDiff
        candidate_max_difference = $taskDistributed.diagnostics.candidate_max_difference
        candidate_equivalent = $taskDistributed.diagnostics.equivalent
        candidate_tolerance = @{
            absolute = $taskDistributed.diagnostics.absolute_tolerance
            relative = $taskDistributed.diagnostics.relative_tolerance
        }
        sequential_diagnostics = $taskSequentialDiagnostics
        distributed_diagnostics = $taskDistributedDiagnostics
        sequential_training_seconds = $taskSequential.run.training_seconds
        distributed_training_seconds = $taskDistributed.run.training_seconds
        sequential_phases = @{
            preparation = $taskSequential.run.preparation_seconds
            compute = $taskSequential.run.training_seconds
            evaluation = $taskSequential.run.evaluation_seconds
            publication = $taskSequential.run.publication_seconds
            total = $taskSequential.run.total_seconds
        }
        distributed_phases = @{
            preparation = $taskDistributed.run.preparation_seconds
            compute = $taskDistributed.run.training_seconds
            evaluation = $taskDistributed.run.evaluation_seconds
            publication = $taskDistributed.run.publication_seconds
            total = $taskDistributed.run.total_seconds
        }
        workers = $taskDistributed.run.workers
        tasks_by_worker = $taskDistributed.run.tasks_by_worker
        test = $taskDistributed.artifact.evaluation.test
        measurement_scope = 'single functional verification; not a benchmark'
    }
    [IO.File]::WriteAllText((Join-Path $taskRepo 'data/training-comparison.json'), ($taskReport | ConvertTo-Json -Depth 6))
    Write-Host ('Máxima diferencia de parámetros publicados: ' + $taskMaxDiff)
    Write-Host ('Máxima diferencia de candidatos previos a selección: ' + $taskDistributed.diagnostics.candidate_max_difference)
    Write-Host ('MAE modelo: ' + $taskReport.test.model.mae + '; baseline: ' + $taskReport.test.persistence_baseline.mae)
    Write-Host 'Resultados guardados en data/training-comparison.json.'
} finally { Pop-Location }
