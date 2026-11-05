[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$Repetitions = 5
)
$ErrorActionPreference = 'Stop'
$null = Import-Module (Join-Path $PSScriptRoot 'benchmark-resources.psm1') -Force -PassThru
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$taskPreviousDatabase = $env:MONGO_DATABASE
$taskPreviousModelOutput = $env:MODEL_OUTPUT
$taskCampaignID = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$taskCampaignRoot = Join-Path 'data/benchmark-training' $taskCampaignID
$taskOutputRoot = Join-Path $taskCampaignRoot 'runs'
$taskConfigRoot = Join-Path $taskCampaignRoot 'configs'
$taskMongoStarted = $false
$taskDockerCommand = $null

function Invoke-DockerCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )
    $taskStdoutPath = Join-Path $taskRepo (Join-Path $taskOutputRoot ($Label + '.stdout.log'))
    $taskStderrPath = Join-Path $taskRepo (Join-Path $taskOutputRoot ($Label + '.stderr.log'))
    $taskProcess = Start-Process -FilePath $taskDockerCommand.Source `
        -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $taskStdoutPath -RedirectStandardError $taskStderrPath
    [pscustomobject]@{
        ExitCode = $taskProcess.ExitCode
        Stdout = if (Test-Path -LiteralPath $taskStdoutPath) { Get-Content -LiteralPath $taskStdoutPath -Raw } else { '' }
        Stderr = if (Test-Path -LiteralPath $taskStderrPath) { Get-Content -LiteralPath $taskStderrPath -Raw } else { '' }
        StdoutPath = $taskStdoutPath
        StderrPath = $taskStderrPath
    }
}

function Get-Median {
    param([double[]]$Values)
    $taskSorted = @($Values | Sort-Object)
    $taskMiddle = [int][Math]::Floor($taskSorted.Count / 2)
    if ($taskSorted.Count % 2 -eq 0) {
        return (($taskSorted[$taskMiddle - 1] + $taskSorted[$taskMiddle]) / 2.0)
    }
    return $taskSorted[$taskMiddle]
}

function Get-TimingSummary {
    param([double[]]$Values)
    if ($Values.Count -eq 0) {
        throw 'At least one timing sample is required.'
    }
    $taskMean = ($Values | Measure-Object -Average).Average
    $taskVariance = 0.0
    foreach ($taskValue in $Values) {
        $taskVariance += [Math]::Pow($taskValue - $taskMean, 2)
    }
    if ($Values.Count -gt 1) {
        $taskVariance /= ($Values.Count - 1)
    }
    [ordered]@{
        count = $Values.Count
        mean_seconds = [Math]::Round($taskMean, 6)
        median_seconds = [Math]::Round((Get-Median $Values), 6)
        min_seconds = [Math]::Round(($Values | Measure-Object -Minimum).Minimum, 6)
        max_seconds = [Math]::Round(($Values | Measure-Object -Maximum).Maximum, 6)
        standard_deviation_seconds = [Math]::Round([Math]::Sqrt($taskVariance), 6)
    }
}

function Write-TrainingConfig {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WorkerCount,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )
    $taskConfig = Get-Content -LiteralPath 'configs/training.json' -Raw | ConvertFrom-Json
    $taskConfig.workers = $WorkerCount
    $taskPath = Join-Path $taskConfigRoot ($Label + '.json')
    [IO.File]::WriteAllText(
        (Join-Path $taskRepo $taskPath),
        ($taskConfig | ConvertTo-Json -Depth 10) + [Environment]::NewLine
    )
    [pscustomobject]@{
        HostPath = Join-Path $taskRepo $taskPath
        ContainerPath = '/app/data/benchmark-training/' + $taskCampaignID + '/configs/' + $Label + '.json'
        Config = $taskConfig
    }
}

function Invoke-TrainingRun {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('sequential', 'distributed')]
        [string]$Mode,
        [Parameter(Mandatory = $true)]
        [int]$WorkerCount,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )
    $taskRunConfig = Write-TrainingConfig -WorkerCount $WorkerCount -Label $Label
    $taskModelOutput = '/app/data/benchmark-training/' + $taskCampaignID + '/models/' + $Label
    $taskArguments = @(
        'compose', '--profile', 'jobs', 'run', '--no-deps', '--rm',
        '-e', ('MONGO_DATABASE=' + $env:MONGO_DATABASE),
        '-e', ('MODEL_OUTPUT=' + $taskModelOutput),
        'trainer', '-mode', $Mode, '-config', $taskRunConfig.ContainerPath
    )
    $taskClock = [Diagnostics.Stopwatch]::StartNew()
    $taskCommand = Invoke-DockerCommand -Arguments $taskArguments -Label $Label
    $taskClock.Stop()
    if ($taskCommand.ExitCode -ne 0) {
        Get-Content -LiteralPath $taskCommand.StdoutPath -ErrorAction SilentlyContinue | Write-Host
        Get-Content -LiteralPath $taskCommand.StderrPath -ErrorAction SilentlyContinue | Write-Host
        throw ('Training failed for ' + $Label + ' with exit code ' + $taskCommand.ExitCode + '.')
    }
    try {
        $taskResult = $taskCommand.Stdout | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw ('Trainer emitted invalid JSON for ' + $Label + ': ' + $_.Exception.Message)
    }
    if (-not $taskResult.run -or -not $taskResult.artifact -or $taskResult.run.status -ne 'completed') {
        throw ('Trainer did not return a completed run and artifact for ' + $Label + '.')
    }
    if ($taskResult.run.mode -ne $Mode -or $taskResult.run.config.workers -ne $WorkerCount) {
        throw ('Trainer returned a mismatched mode or worker configuration for ' + $Label + '.')
    }
    if ($taskResult.run.dataset_id -ne $script:taskDatasetID -or
        $taskResult.artifact.dataset_id -ne $script:taskDatasetID -or
        $taskResult.artifact.snapshot_sha256 -ne $script:taskSnapshotSHA256) {
        throw ('Training used an unexpected dataset or snapshot for ' + $Label + '.')
    }

    $taskRawPath = Join-Path $taskOutputRoot ($Label + '.json')
    [IO.File]::WriteAllText(
        (Join-Path $taskRepo $taskRawPath),
        ($taskResult | ConvertTo-Json -Depth 30) + [Environment]::NewLine
    )
    [pscustomobject]@{
        label = $Label
        mode = $Mode
        workers = $WorkerCount
        run_id = $taskResult.run.run_id
        worker_ids = @($taskResult.run.workers)
        tasks_by_worker = $taskResult.run.tasks_by_worker
        wall_seconds = [Math]::Round($taskClock.Elapsed.TotalSeconds, 6)
        preparation_seconds = $taskResult.run.preparation_seconds
        training_seconds = $taskResult.run.training_seconds
        evaluation_seconds = $taskResult.run.evaluation_seconds
        dataset_id = $taskResult.artifact.dataset_id
        snapshot_sha256 = $taskResult.artifact.snapshot_sha256
        artifact_version = $taskResult.artifact.version
        selection = $taskResult.artifact.selection
        evaluation = $taskResult.artifact.evaluation
        weights = @($taskResult.artifact.weights)
        config = $taskRunConfig.Config
    }
}

Push-Location $taskRepo
try {
    New-Item -ItemType Directory -Force -Path $taskOutputRoot, $taskConfigRoot | Out-Null
    & (Join-Path $PSScriptRoot 'benchmark-preflight.ps1')
    if (-not $?) {
        throw 'Benchmark preflight failed.'
    }
    $taskPreflight = Get-Content -LiteralPath 'data/benchmark-preflight.json' -Raw | ConvertFrom-Json
    if (-not $taskPreflight.ready_for_measurements) {
        throw 'Benchmark preflight did not approve this environment.'
    }

    $taskDockerCommand = Get-Command docker -ErrorAction Stop
    $taskComposeConfigCommand = Invoke-DockerCommand -Arguments @('compose', '--profile', 'jobs', 'config', '--format', 'json') -Label 'compose-config'
    if ($taskComposeConfigCommand.ExitCode -ne 0) {
        throw 'Could not resolve the project Compose configuration.'
    }
    $taskComposeConfig = $taskComposeConfigCommand.Stdout | ConvertFrom-Json
    $taskSourceDatabase = [string]$taskComposeConfig.services.master.environment.MONGO_DATABASE
    if ([string]::IsNullOrWhiteSpace($taskSourceDatabase) -or $taskSourceDatabase -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'The source MongoDB database name is missing or invalid.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$taskComposeConfig.services.master.environment.MASTER_API_TOKEN)) {
        throw 'MASTER_API_TOKEN is required to start the benchmark master.'
    }
    if ($taskPreflight.repository.worktree_dirty) {
        throw 'Commit or discard code changes before benchmarking so the campaign refers to a reproducible checkout.'
    }

    $taskBenchmarkDatabase = 'training_bench_' + $taskCampaignID.Replace('T', '_').Replace('Z', '')
    $taskBenchmarkModelOutput = '/app/data/benchmark-training/' + $taskCampaignID + '/models'
    $env:MONGO_DATABASE = $taskBenchmarkDatabase
    $env:MODEL_OUTPUT = $taskBenchmarkModelOutput

    $taskBuild = Invoke-DockerCommand -Arguments @('compose', '--profile', 'jobs', 'build', 'trainer', 'master', 'worker') -Label 'build'
    if ($taskBuild.ExitCode -ne 0) {
        Get-Content -LiteralPath $taskBuild.StdoutPath -ErrorAction SilentlyContinue | Write-Host
        Get-Content -LiteralPath $taskBuild.StderrPath -ErrorAction SilentlyContinue | Write-Host
        throw 'Could not build the trainer, master, and worker images.'
    }

    $taskMongoStart = Invoke-DockerCommand -Arguments @('compose', 'up', '-d', '--wait', 'mongo') -Label 'mongo-start'
    if ($taskMongoStart.ExitCode -ne 0) {
        Get-Content -LiteralPath $taskMongoStart.StdoutPath -ErrorAction SilentlyContinue | Write-Host
        Get-Content -LiteralPath $taskMongoStart.StderrPath -ErrorAction SilentlyContinue | Write-Host
        throw 'Could not start MongoDB for the isolated benchmark database.'
    }
    $taskMongoStarted = $true

    $taskSeedJS = 'const s=db.getSiblingDB("' + $taskSourceDatabase + '");const t=db.getSiblingDB("' + $taskBenchmarkDatabase + '");const c=s.settings.findOne({_id:"current_dataset"});if(!c)throw new Error("source current_dataset setting not found");const m=s.datasets.findOne({_id:c.dataset_id,status:"complete"});if(!m)throw new Error("source complete manifest not found");if(!m.snapshot||!m.snapshot.sha256||!m.snapshot.path)throw new Error("source manifest snapshot is incomplete");t.datasets.insertOne(m);t.settings.insertOne(c);print("BENCHMARK_SEED:"+JSON.stringify({dataset_id:m._id,snapshot_sha256:m.snapshot.sha256,examples:m.snapshot.examples,snapshot_path:m.snapshot.path}));'
    $taskSeed = Invoke-DockerCommand -Arguments @('compose', 'exec', '-T', 'mongo', 'mongosh', '--quiet', '--eval', $taskSeedJS) -Label 'seed'
    if ($taskSeed.ExitCode -ne 0) {
        Get-Content -LiteralPath $taskSeed.StdoutPath -ErrorAction SilentlyContinue | Write-Host
        Get-Content -LiteralPath $taskSeed.StderrPath -ErrorAction SilentlyContinue | Write-Host
        throw 'Could not copy the current dataset manifest to the isolated benchmark database.'
    }
    $taskSeedLine = @($taskSeed.Stdout -split "`r?`n" | Where-Object { $_.StartsWith('BENCHMARK_SEED:') }) | Select-Object -Last 1
    if (-not $taskSeedLine) {
        throw 'MongoDB did not confirm the isolated dataset seed.'
    }
    $taskSeedResult = $taskSeedLine.Substring('BENCHMARK_SEED:'.Length) | ConvertFrom-Json
    $script:taskDatasetID = [string]$taskSeedResult.dataset_id
    $script:taskSnapshotSHA256 = [string]$taskSeedResult.snapshot_sha256
    $taskSnapshotHostPath = Join-Path $taskRepo ([string]$taskSeedResult.snapshot_path)
    if (-not (Test-Path -LiteralPath $taskSnapshotHostPath -PathType Leaf)) {
        throw ('Dataset snapshot is not available on the host: ' + $taskSnapshotHostPath)
    }
    $taskActualSnapshotHash = (Get-FileHash -LiteralPath $taskSnapshotHostPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($taskActualSnapshotHash -ne $script:taskSnapshotSHA256) {
        throw 'Dataset snapshot checksum does not match the MongoDB manifest.'
    }
    $taskTrainingConfig = Get-Content -LiteralPath 'configs/training.json' -Raw | ConvertFrom-Json
    $taskExpectedParameterConfig = @(
        [string]$taskTrainingConfig.epochs,
        [string]$taskTrainingConfig.batch_size,
        [string]$taskTrainingConfig.learning_rate,
        [string]$taskTrainingConfig.l2,
        [string]$taskTrainingConfig.seed,
        [string]$taskTrainingConfig.task_timeout_seconds
    ) -join '|'
    $taskWarmup = Invoke-TrainingRun -Mode sequential -WorkerCount 1 -Label 'warmup-sequential'
    $taskMeasurements = @()
    $taskRounds = @()

    for ($taskRound = 1; $taskRound -le $Repetitions; $taskRound++) {
        $taskCases = @(
            [pscustomobject]@{ mode = 'sequential'; workers = 1; key = 'sequential-1' },
            [pscustomobject]@{ mode = 'distributed'; workers = 1; key = 'distributed-1' },
            [pscustomobject]@{ mode = 'distributed'; workers = 2; key = 'distributed-2' },
            [pscustomobject]@{ mode = 'distributed'; workers = 4; key = 'distributed-4' }
        )
        $taskRotation = ($taskRound - 1) % $taskCases.Count
        if ($taskRotation -eq 0) {
            $taskOrderedCases = $taskCases
        } else {
            $taskOrderedCases = @($taskCases[$taskRotation..($taskCases.Count - 1)] + $taskCases[0..($taskRotation - 1)])
        }
        $taskRoundResults = @{}

        foreach ($taskCase in $taskOrderedCases) {
            $taskLabel = 'round-{0:D2}-{1}' -f $taskRound, $taskCase.key
            if ($taskCase.mode -eq 'sequential') {
                $taskStopCluster = Invoke-DockerCommand -Arguments @('compose', 'stop', 'master', 'worker') -Label ($taskLabel + '-stop-cluster')
                if ($taskStopCluster.ExitCode -ne 0) {
                    Get-Content -LiteralPath $taskStopCluster.StderrPath -ErrorAction SilentlyContinue | Write-Host
                    throw 'Could not stop distributed services before sequential training.'
                }
            } else {
                $taskScale = Invoke-DockerCommand -Arguments @(
                    'compose', 'up', '-d', '--wait', '--scale', ('worker=' + $taskCase.workers), 'master', 'worker'
                ) -Label ($taskLabel + '-scale')
                if ($taskScale.ExitCode -ne 0) {
                    Get-Content -LiteralPath $taskScale.StdoutPath -ErrorAction SilentlyContinue | Write-Host
                    Get-Content -LiteralPath $taskScale.StderrPath -ErrorAction SilentlyContinue | Write-Host
                    throw ('Could not start ' + $taskCase.workers + ' healthy workers.')
                }
            }

            $taskCapturePath = Join-Path $taskOutputRoot ($taskLabel + '.resources.jsonl')
            $taskCapture = Start-BenchmarkResourceCapture `
                -ProjectName ([string]$taskComposeConfig.name) `
                -OutputPath (Join-Path $taskRepo $taskCapturePath)
            $taskRunError = $null
            $taskRecord = $null
            try {
                $taskRecord = Invoke-TrainingRun -Mode $taskCase.mode -WorkerCount $taskCase.workers -Label $taskLabel
            } catch {
                $taskRunError = $_
            }
            try {
                $taskResourceSummary = Stop-BenchmarkResourceCapture -Capture $taskCapture
            } catch {
                if ($taskRunError) {
                    throw ('Training failed: ' + $taskRunError.Exception.Message + '; resource capture failed: ' + $_.Exception.Message)
                }
                throw
            }
            if ($taskRunError) {
                throw $taskRunError
            }
            $taskRecord | Add-Member -NotePropertyName resources -NotePropertyValue $taskResourceSummary
            if ($taskRecord.mode -eq 'distributed') {
                $taskWorkerIDs = @($taskRecord.worker_ids | Sort-Object -Unique)
                if ($taskWorkerIDs.Count -ne $taskCase.workers) {
                    throw ('Expected ' + $taskCase.workers + ' distinct workers in ' + $taskLabel + '.')
                }
                foreach ($taskWorkerID in $taskWorkerIDs) {
                    $taskWorkerTaskCount = [int]$taskRecord.tasks_by_worker.$taskWorkerID
                    if ($taskWorkerTaskCount -le 0) {
                        throw ('Worker did not contribute training tasks in ' + $taskLabel + ': ' + $taskWorkerID)
                    }
                }
            }
            $taskComparableConfig = @(
                [string]$taskRecord.config.epochs,
                [string]$taskRecord.config.batch_size,
                [string]$taskRecord.config.learning_rate,
                [string]$taskRecord.config.l2,
                [string]$taskRecord.config.seed,
                [string]$taskRecord.config.task_timeout_seconds
            ) -join '|'
            if ($taskComparableConfig -ne $taskExpectedParameterConfig) {
                throw ('Training parameters changed during the campaign: ' + $taskLabel)
            }
            $taskRoundResults[$taskCase.key] = $taskRecord
            $taskMeasurements += $taskRecord
            Write-Host ($taskLabel + ': ' + $taskRecord.training_seconds + ' seconds; mode=' + $taskRecord.mode)
        }

        $taskBaseline = $taskRoundResults['sequential-1']
        foreach ($taskWorkerCount in @(1, 2, 4)) {
            $taskDistributed = $taskRoundResults['distributed-' + $taskWorkerCount]
            if ($taskBaseline.weights.Count -ne $taskDistributed.weights.Count) {
                throw ('Sequential and distributed model dimensions differ in round ' + $taskRound + '.')
            }
            $taskMaxWeightDifference = 0.0
            for ($taskIndex = 0; $taskIndex -lt $taskBaseline.weights.Count; $taskIndex++) {
                $taskMaxWeightDifference = [Math]::Max(
                    $taskMaxWeightDifference,
                    [Math]::Abs([double]$taskBaseline.weights[$taskIndex] - [double]$taskDistributed.weights[$taskIndex])
                )
            }
            if ($taskMaxWeightDifference -gt 1e-9) {
                throw ('Sequential/distributed model mismatch in round ' + $taskRound + ' with ' + $taskWorkerCount + ' workers: ' + $taskMaxWeightDifference)
            }
            $taskDistributed | Add-Member -NotePropertyName max_weight_difference_from_sequential -NotePropertyValue $taskMaxWeightDifference
        }
        $taskRounds += [pscustomobject]@{
            round = $taskRound
            order = @($taskOrderedCases | ForEach-Object { $_.key })
            max_weight_difference_by_worker_count = [ordered]@{
                '1' = $taskRoundResults['distributed-1'].max_weight_difference_from_sequential
                '2' = $taskRoundResults['distributed-2'].max_weight_difference_from_sequential
                '4' = $taskRoundResults['distributed-4'].max_weight_difference_from_sequential
            }
        }
    }

    $taskSummaries = @()
    foreach ($taskKey in @('sequential-1', 'distributed-1', 'distributed-2', 'distributed-4')) {
        $taskRows = @($taskMeasurements | Where-Object {
            if ($taskKey -eq 'sequential-1') { $_.mode -eq 'sequential' } else { $_.label.EndsWith($taskKey) }
        })
        if ($taskRows.Count -ne $Repetitions) {
            throw ('Incomplete repeat count for ' + $taskKey + '.')
        }
        $taskTrainingTimes = [double[]]@($taskRows | ForEach-Object { [double]$_.training_seconds })
        $taskWallTimes = [double[]]@($taskRows | ForEach-Object { [double]$_.wall_seconds })
        $taskSummaries += [pscustomobject]@{
            case = $taskKey
            mode = $taskRows[0].mode
            workers = $taskRows[0].workers
            training_timing = Get-TimingSummary $taskTrainingTimes
            wall_timing = Get-TimingSummary $taskWallTimes
            all_workers_contributed = if ($taskRows[0].mode -eq 'sequential') {
                $true
            } else {
                @($taskRows | Where-Object {
                    @($_.worker_ids | Sort-Object -Unique).Count -ne $_.workers
                }).Count -eq 0
            }
            max_weight_difference_from_sequential = if ($taskRows[0].mode -eq 'sequential') {
                0.0
            } else {
                [Math]::Round(($taskRows | Measure-Object -Property max_weight_difference_from_sequential -Maximum).Maximum, 12)
            }
        }
    }
    $taskSequentialMedian = [double]$taskSummaries[0].training_timing.median_seconds
    foreach ($taskSummary in @($taskSummaries | Select-Object -Skip 1)) {
        $taskSummary | Add-Member -NotePropertyName speedup_vs_sequential_median -NotePropertyValue (
            if ([double]$taskSummary.training_timing.median_seconds -gt 0) {
                [Math]::Round($taskSequentialMedian / [double]$taskSummary.training_timing.median_seconds, 4)
            } else {
                $null
            }
        )
    }

    $taskReport = [ordered]@{
        campaign_id = $taskCampaignID
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        status = 'complete'
        commit = $taskPreflight.repository.commit
        branch = $taskPreflight.repository.branch
        worktree_dirty = $taskPreflight.repository.worktree_dirty
        repetitions_per_case = $Repetitions
        warmup = [ordered]@{
            mode = $taskWarmup.mode
            workers = $taskWarmup.workers
            wall_seconds = $taskWarmup.wall_seconds
            training_seconds = $taskWarmup.training_seconds
        }
        isolation = [ordered]@{
            source_database = $taskSourceDatabase
            benchmark_database = $taskBenchmarkDatabase
            demo_database_modified = $false
            demo_model_output_modified = $false
            benchmark_database_dropped_after_run = $true
        }
        dataset = [ordered]@{
            dataset_id = $script:taskDatasetID
            snapshot_sha256 = $script:taskSnapshotSHA256
            snapshot_path = $taskSeedResult.snapshot_path
            examples = $taskSeedResult.examples
            snapshot_checksum_verified = $true
        }
        training_config = $taskTrainingConfig
        host = $taskPreflight.host
        docker = $taskPreflight.docker
        model_equivalence_tolerance = 1e-9
        summaries = @($taskSummaries)
        rounds = @($taskRounds)
        measurements = @($taskMeasurements | ForEach-Object {
            $taskRow = $_ | Select-Object *
            $taskRow.PSObject.Properties.Remove('weights')
            $taskRow
        })
        interpretation = 'Single-host training comparison. Reported speedup uses median training_seconds relative to sequential training; it does not imply multi-host scaling.'
        raw_run_artifacts = 'Complete trainer JSON output is stored per run under this campaign directory; data/models are isolated per run.'
    }
    $taskReportPath = Join-Path $taskCampaignRoot 'report.json'
    [IO.File]::WriteAllText(
        (Join-Path $taskRepo $taskReportPath),
        ($taskReport | ConvertTo-Json -Depth 30) + [Environment]::NewLine
    )
    Write-Host ('Training benchmark complete. Report: ' + $taskReportPath)
    foreach ($taskSummary in $taskSummaries) {
        Write-Host ($taskSummary.case + ': median training ' + $taskSummary.training_timing.median_seconds + ' s')
    }
} finally {
    if ($taskMongoStarted -and $taskDockerCommand) {
        $taskDropJS = 'const r=db.getSiblingDB("' + $taskBenchmarkDatabase + '").dropDatabase();if(!r.ok)throw new Error("failed to drop benchmark database");print("BENCHMARK_DROP:"+JSON.stringify(r));'
        $taskDrop = Invoke-DockerCommand -Arguments @('compose', 'exec', '-T', 'mongo', 'mongosh', '--quiet', '--eval', $taskDropJS) -Label 'drop-database'
        if ($taskDrop.ExitCode -ne 0) {
            Write-Warning ('Could not remove isolated benchmark database ' + $taskBenchmarkDatabase + '. Inspect ' + $taskDrop.StderrPath)
        }
        $taskStop = Invoke-DockerCommand -Arguments @('compose', 'stop', 'master', 'worker', 'mongo') -Label 'cleanup-stop'
        if ($taskStop.ExitCode -ne 0) {
            Write-Warning ('Could not stop all benchmark services. Inspect ' + $taskStop.StderrPath)
        }
    }
    if ($null -eq $taskPreviousDatabase) {
        Remove-Item Env:MONGO_DATABASE -ErrorAction SilentlyContinue
    } else {
        $env:MONGO_DATABASE = $taskPreviousDatabase
    }
    if ($null -eq $taskPreviousModelOutput) {
        Remove-Item Env:MODEL_OUTPUT -ErrorAction SilentlyContinue
    } else {
        $env:MODEL_OUTPUT = $taskPreviousModelOutput
    }
    Pop-Location
}
