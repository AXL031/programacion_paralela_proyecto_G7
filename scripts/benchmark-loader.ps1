[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$Repetitions = 5
)
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $taskRepo
try {
    & (Join-Path $PSScriptRoot 'benchmark-preflight.ps1')
    if (-not $?) { throw 'Benchmark preflight failed.' }
    $taskPreflight = Get-Content -LiteralPath 'data/benchmark-preflight.json' -Raw | ConvertFrom-Json
    if (-not $taskPreflight.ready_for_measurements) {
        throw 'Benchmark preflight did not approve this environment.'
    }

    $taskCampaignID = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $taskCampaignRoot = Join-Path 'data/benchmark-loader' $taskCampaignID
    $taskResultsRoot = Join-Path $taskCampaignRoot 'results'
    $taskConfigsRoot = Join-Path $taskCampaignRoot 'configs'
    New-Item -ItemType Directory -Force -Path $taskResultsRoot, $taskConfigsRoot | Out-Null

    $taskBaseConfig = Get-Content -LiteralPath 'configs/demo.json' -Raw | ConvertFrom-Json
    $taskSourceConfig = Get-Content -LiteralPath 'configs/sources.json' -Raw | ConvertFrom-Json
    $taskExpectedFiles = @{}
    foreach ($taskSource in $taskSourceConfig.files) {
        $taskExpectedFiles[$taskSource.name] = $taskSource.sha256
    }

    $taskDockerCommand = Get-Command docker -ErrorAction Stop
    $taskBuildStdout = Join-Path $taskRepo (Join-Path $taskResultsRoot 'docker-build.stdout.log')
    $taskBuildStderr = Join-Path $taskRepo (Join-Path $taskResultsRoot 'docker-build.stderr.log')
    $taskBuildProcess = Start-Process -FilePath $taskDockerCommand.Source `
        -ArgumentList @('compose', '--profile', 'jobs', 'build', 'loader') `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $taskBuildStdout -RedirectStandardError $taskBuildStderr
    if ($taskBuildProcess.ExitCode -ne 0) {
        Get-Content -LiteralPath $taskBuildStdout -ErrorAction SilentlyContinue | Write-Host
        Get-Content -LiteralPath $taskBuildStderr -ErrorAction SilentlyContinue | Write-Host
        throw 'Could not build the loader image.'
    }

    function Invoke-LoaderMeasurement {
        param(
            [Parameter(Mandatory = $true)]
            [int]$WorkerCount,
            [Parameter(Mandatory = $true)]
            [string]$Label,
            [Parameter(Mandatory = $true)]
            [bool]$Warmup
        )

        $taskWorkRelative = ($taskCampaignRoot + '/work/' + $Label).Replace('\', '/')
        $taskContainerConfig = '/app/data/benchmark-loader/' + $taskCampaignID + '/configs/' + $Label + '.json'
        $taskHostConfig = Join-Path $taskConfigsRoot ($Label + '.json')
        $taskRunConfig = $taskBaseConfig | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $taskRunConfig.workers = $WorkerCount
        $taskRunConfig.storage = 'files'
        $taskRunConfig.output = $taskWorkRelative
        $taskRunConfig.mongo_uri = ''
        $taskRunConfig.mongo_database = ''
        [IO.File]::WriteAllText(
            (Join-Path $taskRepo $taskHostConfig),
            ($taskRunConfig | ConvertTo-Json -Depth 10) + [Environment]::NewLine
        )

        $taskArgs = @(
            'compose', '--profile', 'jobs', 'run', '--no-deps', '--rm',
            'loader', '-config', $taskContainerConfig
        )
        $taskStdoutPath = Join-Path $taskResultsRoot ($Label + '.stdout.log')
        $taskStderrPath = Join-Path $taskResultsRoot ($Label + '.stderr.log')
        $taskClock = [Diagnostics.Stopwatch]::StartNew()
        $taskProcess = Start-Process -FilePath $taskDockerCommand.Source `
            -ArgumentList $taskArgs -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput (Join-Path $taskRepo $taskStdoutPath) `
            -RedirectStandardError (Join-Path $taskRepo $taskStderrPath)
        $taskExitCode = $taskProcess.ExitCode
        $taskClock.Stop()
        if ($taskExitCode -ne 0) {
            Get-Content -LiteralPath $taskStdoutPath -ErrorAction SilentlyContinue | Write-Host
            Get-Content -LiteralPath $taskStderrPath -ErrorAction SilentlyContinue | Write-Host
            throw ('Loader run failed: ' + $Label + ' (exit ' + $taskExitCode + ').')
        }

        $taskText = Get-Content -LiteralPath $taskStdoutPath -Raw
        try {
            $taskResult = $taskText | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw ('Loader emitted invalid JSON for ' + $Label + ': ' + $_.Exception.Message)
        }
        $taskManifest = $taskResult.manifest
        $taskStats = $taskManifest.stats
        $taskSnapshot = $taskManifest.snapshot
        if (-not $taskManifest -or $taskManifest.status -ne 'complete') {
            throw ('Loader did not publish a complete dataset for ' + $Label + '.')
        }
        if ($taskResult.reused) {
            throw ('Loader unexpectedly reused prior output for ' + $Label + '.')
        }
        if ($taskStats.accepted -ne $taskStats.persisted -or
            $taskStats.read -ne ($taskStats.accepted + $taskStats.rejected + $taskStats.outside_period)) {
            throw ('Loader row-accounting invariant failed for ' + $Label + '.')
        }
        if ($taskSnapshot.sha256 -notmatch '^[a-f0-9]{64}$' -or
            $taskSnapshot.examples -le 0 -or $taskSnapshot.windows -le 0) {
            throw ('Loader snapshot is incomplete for ' + $Label + '.')
        }

        $taskRecord = [ordered]@{
            label = $Label
            warmup = $Warmup
            workers = $WorkerCount
            wall_seconds = [Math]::Round($taskClock.Elapsed.TotalSeconds, 6)
            loader_seconds = $taskStats.elapsed_seconds
            rows_per_second = $taskStats.rows_per_second
            dataset_id = $taskManifest.dataset_id
            source_sha256 = $taskManifest.source_sha256
            catalog_sha256 = $taskManifest.catalog_sha256
            stats = $taskStats
            snapshot = [ordered]@{
                sha256 = $taskSnapshot.sha256
                windows = $taskSnapshot.windows
                examples = $taskSnapshot.examples
                splits = $taskSnapshot.splits
            }
        }
        $taskRecordPath = Join-Path $taskResultsRoot ($Label + '.json')
        [IO.File]::WriteAllText(
            (Join-Path $taskRepo $taskRecordPath),
            ($taskRecord | ConvertTo-Json -Depth 10) + [Environment]::NewLine
        )

        $taskWorkHost = Join-Path $taskRepo $taskWorkRelative
        if (Test-Path -LiteralPath $taskWorkHost) {
            $taskResolvedWork = (Resolve-Path -LiteralPath $taskWorkHost).Path
            $taskResolvedCampaign = (Resolve-Path -LiteralPath (Join-Path $taskRepo $taskCampaignRoot)).Path
            if (-not $taskResolvedWork.StartsWith($taskResolvedCampaign + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw ('Refusing to remove a run directory outside the campaign: ' + $taskResolvedWork)
            }
            Remove-Item -LiteralPath $taskResolvedWork -Recurse -Force
        }
        return [pscustomobject]$taskRecord
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

    function Get-Statistics {
        param([double[]]$Values)
        $taskMean = ($Values | Measure-Object -Average).Average
        $taskVariance = 0.0
        foreach ($taskValue in $Values) {
            $taskVariance += [Math]::Pow($taskValue - $taskMean, 2)
        }
        if ($Values.Count -gt 1) {
            $taskVariance /= ($Values.Count - 1)
        }
        return [ordered]@{
            count = $Values.Count
            mean_seconds = [Math]::Round($taskMean, 6)
            median_seconds = [Math]::Round((Get-Median $Values), 6)
            min_seconds = [Math]::Round(($Values | Measure-Object -Minimum).Minimum, 6)
            max_seconds = [Math]::Round(($Values | Measure-Object -Maximum).Maximum, 6)
            standard_deviation_seconds = [Math]::Round([Math]::Sqrt($taskVariance), 6)
        }
    }

    $taskWarmup = Invoke-LoaderMeasurement -WorkerCount 1 -Label 'warmup-workers-1' -Warmup $true
    $taskSamples = @()
    for ($taskRound = 1; $taskRound -le $Repetitions; $taskRound++) {
        if ($taskRound % 2 -eq 1) {
            $taskOrder = @(1, 4)
        } else {
            $taskOrder = @(4, 1)
        }
        foreach ($taskWorkerCount in $taskOrder) {
            $taskLabel = 'round-{0:D2}-workers-{1}' -f $taskRound, $taskWorkerCount
            $taskSamples += Invoke-LoaderMeasurement -WorkerCount $taskWorkerCount -Label $taskLabel -Warmup $false
            Write-Host ($taskLabel + ': ' + $taskSamples[-1].loader_seconds + ' seconds; ' + $taskSamples[-1].rows_per_second + ' rows/s')
        }
    }

    $taskReference = $taskSamples[0]
    foreach ($taskSample in $taskSamples) {
        $taskExpectedRejected = $taskReference.stats.rejected
        $taskExpectedReasons = $taskReference.stats.rejection_reasons | ConvertTo-Json -Compress -Depth 10
        $taskActualReasons = $taskSample.stats.rejection_reasons | ConvertTo-Json -Compress -Depth 10
        if ($taskSample.dataset_id -ne $taskReference.dataset_id -or
            $taskSample.source_sha256 -ne $taskReference.source_sha256 -or
            $taskSample.catalog_sha256 -ne $taskReference.catalog_sha256 -or
            $taskSample.stats.read -ne $taskReference.stats.read -or
            $taskSample.stats.accepted -ne $taskReference.stats.accepted -or
            $taskSample.stats.persisted -ne $taskReference.stats.persisted -or
            $taskSample.stats.rejected -ne $taskExpectedRejected -or
            $taskSample.stats.outside_period -ne $taskReference.stats.outside_period -or
            $taskActualReasons -ne $taskExpectedReasons -or
            $taskSample.snapshot.sha256 -ne $taskReference.snapshot.sha256 -or
            $taskSample.snapshot.windows -ne $taskReference.snapshot.windows -or
            $taskSample.snapshot.examples -ne $taskReference.snapshot.examples) {
            throw ('Worker configurations produced different output or accounting: ' + $taskSample.label)
        }
    }

    $taskWorkerSummaries = @()
    foreach ($taskWorkerCount in @(1, 4)) {
        $taskWorkerSamples = @($taskSamples | Where-Object { $_.workers -eq $taskWorkerCount })
        $taskDurations = [double[]]@($taskWorkerSamples | ForEach-Object { [double]$_.loader_seconds })
        $taskThroughputs = [double[]]@($taskWorkerSamples | ForEach-Object { [double]$_.rows_per_second })
        $taskWorkerSummaries += [pscustomobject]@{
            workers = $taskWorkerCount
            timing = Get-Statistics $taskDurations
            throughput_rows_per_second = [ordered]@{
                mean = [Math]::Round(($taskThroughputs | Measure-Object -Average).Average, 3)
                median = [Math]::Round((Get-Median $taskThroughputs), 3)
            }
        }
    }
    $taskOneWorkerMedian = [double]$taskWorkerSummaries[0].timing.median_seconds
    $taskFourWorkerMedian = [double]$taskWorkerSummaries[1].timing.median_seconds
    $taskReport = [ordered]@{
        campaign_id = $taskCampaignID
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        status = 'complete'
        commit = $taskPreflight.repository.commit
        branch = $taskPreflight.repository.branch
        worktree_dirty = $taskPreflight.repository.worktree_dirty
        repetitions_per_worker_count = $Repetitions
        warmup = $taskWarmup
        configuration = [ordered]@{
            source = $taskBaseConfig.name
            input_sha256 = $taskExpectedFiles[$taskBaseConfig.input.Split('/')[-1]]
            zone_catalog_sha256 = $taskExpectedFiles[$taskBaseConfig.zone_catalog.Split('/')[-1]]
            period_start = $taskBaseConfig.period_start
            period_end_exclusive = $taskBaseConfig.period_end_exclusive
            window_minutes = $taskBaseConfig.window_minutes
            block_rows = $taskBaseConfig.block_rows
            batch_rows = $taskBaseConfig.batch_rows
            storage = 'isolated files backend; output removed after each successful run'
        }
        host = $taskPreflight.host
        docker = $taskPreflight.docker
        verified_equivalence = [ordered]@{
            all_run_count_and_rejection_stats_match = $true
            all_snapshot_sha256_match = $true
            dataset_id = $taskReference.dataset_id
            source_sha256 = $taskReference.source_sha256
            catalog_sha256 = $taskReference.catalog_sha256
            snapshot_sha256 = $taskReference.snapshot.sha256
            read = $taskReference.stats.read
            accepted = $taskReference.stats.accepted
            rejected = $taskReference.stats.rejected
            outside_period = $taskReference.stats.outside_period
            persisted = $taskReference.stats.persisted
            windows = $taskReference.snapshot.windows
            examples = $taskReference.snapshot.examples
            splits = $taskReference.snapshot.splits
        }
        summaries = @($taskWorkerSummaries)
        speedup_1_vs_4_workers = if ($taskFourWorkerMedian -gt 0) {
            [Math]::Round($taskOneWorkerMedian / $taskFourWorkerMedian, 4)
        } else {
            $null
        }
        measurements = @($taskSamples)
        interpretation = 'Loader-only comparison on one host. A speedup above 1 indicates four workers were faster in this campaign; it does not establish distributed training speedup.'
        artifacts = 'Per-run JSON and this report are retained; successful per-run trip, window, and feature files are removed after their checksums and counts are recorded.'
    }
    $taskReportPath = Join-Path $taskCampaignRoot 'report.json'
    [IO.File]::WriteAllText(
        (Join-Path $taskRepo $taskReportPath),
        ($taskReport | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    )
    Write-Host ('Loader benchmark complete. Report: ' + $taskReportPath)
    Write-Host ('Equivalent snapshots: ' + $taskReference.snapshot.sha256)
    Write-Host ('Median speedup, 1 vs 4 workers: ' + $taskReport.speedup_1_vs_4_workers)
} finally {
    Pop-Location
}
