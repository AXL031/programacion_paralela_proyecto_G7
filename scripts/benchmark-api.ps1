[CmdletBinding()]
param(
    [ValidateRange(10, 5000)]
    [int]$Requests = 300,
    [ValidateRange(1, 64)]
    [int]$Concurrency = 8,
    [ValidateRange(0, 100)]
    [int]$WarmupRequests = 20,
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 15
)
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$taskOutputDirectory = $null
$taskDockerCommand = $null
$taskPreviousProgressPreference = $ProgressPreference

function Invoke-DockerCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )
    $taskStdoutPath = Join-Path $taskOutputDirectory ($Label + '.stdout.log')
    $taskStderrPath = Join-Path $taskOutputDirectory ($Label + '.stderr.log')
    $taskProcess = Start-Process -FilePath $taskDockerCommand.Source `
        -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $taskStdoutPath -RedirectStandardError $taskStderrPath
    [pscustomobject]@{
        ExitCode = $taskProcess.ExitCode
        Stdout = if (Test-Path -LiteralPath $taskStdoutPath) { Get-Content -LiteralPath $taskStdoutPath -Raw } else { '' }
        Stderr = if (Test-Path -LiteralPath $taskStderrPath) { Get-Content -LiteralPath $taskStderrPath -Raw } else { '' }
    }
}

function ConvertTo-UtcDateTimeOffset {
    param([Parameter(Mandatory = $true)]$Value)
    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime()
    }
    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    ).ToUniversalTime()
}

function Get-Percentile {
    param(
        [Parameter(Mandatory = $true)]
        [double[]]$Values,
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 100)]
        [double]$Percentile
    )
    if ($Values.Count -eq 0) {
        return $null
    }
    $taskSorted = @($Values | Sort-Object)
    $taskIndex = [Math]::Max(0, [Math]::Ceiling(($Percentile / 100.0) * $taskSorted.Count) - 1)
    return [double]$taskSorted[$taskIndex]
}

function Get-PassSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [object[]]$Samples,
        [Parameter(Mandatory = $true)]
        [double]$ElapsedSeconds,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedModelVersion
    )
    $taskStatuses = @{}
    foreach ($taskSample in $Samples) {
        $taskStatusKey = [string]$taskSample.StatusCode
        if (-not $taskStatuses.ContainsKey($taskStatusKey)) {
            $taskStatuses[$taskStatusKey] = 0
        }
        $taskStatuses[$taskStatusKey]++
    }
    $taskSuccessful = @($Samples | Where-Object {
        $_.StatusCode -eq 200 -and $_.CacheHitKnown -and $_.ServerLatencyKnown -and $_.ModelVersion -eq $ExpectedModelVersion
    })
    $taskErrors = @($Samples | Where-Object {
        $_.StatusCode -ne 200 -or -not $_.CacheHitKnown -or -not $_.ServerLatencyKnown -or $_.ModelVersion -ne $ExpectedModelVersion
    })
    $taskLatencies = [double[]]@($Samples | ForEach-Object { [double]$_.ElapsedMilliseconds })
    $taskServerLatencies = [double[]]@($taskSuccessful | ForEach-Object { [double]$_.ServerLatencyMilliseconds })
    $taskCacheHits = @($taskSuccessful | Where-Object { $_.CacheHit }).Count
    $taskCacheMisses = @($taskSuccessful | Where-Object { -not $_.CacheHit }).Count
    $taskErrorKinds = @{}
    foreach ($taskError in $taskErrors) {
        $taskKey = if ($taskError.Error) { [string]$taskError.Error } else { 'unexpected_response' }
        if (-not $taskErrorKinds.ContainsKey($taskKey)) {
            $taskErrorKinds[$taskKey] = 0
        }
        $taskErrorKinds[$taskKey]++
    }
    [ordered]@{
        name = $Name
        requests = $Samples.Count
        completed = $taskSuccessful.Count
        errors = $taskErrors.Count
        error_kinds = $taskErrorKinds
        http_status_counts = $taskStatuses
        elapsed_seconds = [Math]::Round($ElapsedSeconds, 6)
        throughput_requests_per_second = if ($ElapsedSeconds -gt 0) {
            [Math]::Round($taskSuccessful.Count / $ElapsedSeconds, 3)
        } else {
            0
        }
        http_latency_ms = [ordered]@{
            p50 = if ($taskLatencies.Count -gt 0) { [Math]::Round((Get-Percentile -Values $taskLatencies -Percentile 50), 3) } else { $null }
            p95 = if ($taskLatencies.Count -gt 0) { [Math]::Round((Get-Percentile -Values $taskLatencies -Percentile 95), 3) } else { $null }
            p99 = if ($taskLatencies.Count -gt 0) { [Math]::Round((Get-Percentile -Values $taskLatencies -Percentile 99), 3) } else { $null }
            max = [Math]::Round(($taskLatencies | Measure-Object -Maximum).Maximum, 3)
        }
        objective_100ms = [ordered]@{
            p95_under_100_ms = if ($taskLatencies.Count -gt 0) {
                [double](Get-Percentile -Values $taskLatencies -Percentile 95) -lt 100
            } else {
                $false
            }
            successful_requests_under_100_ms = @($taskSuccessful | Where-Object { $_.ElapsedMilliseconds -lt 100 }).Count
            percent_successful_requests_under_100_ms = if ($taskSuccessful.Count -gt 0) {
                [Math]::Round(
                    (@($taskSuccessful | Where-Object { $_.ElapsedMilliseconds -lt 100 }).Count / [double]$taskSuccessful.Count) * 100,
                    3
                )
            } else {
                $null
            }
        }
        server_latency_ms = [ordered]@{
            p50 = if ($taskServerLatencies.Count -gt 0) { [Math]::Round((Get-Percentile -Values $taskServerLatencies -Percentile 50), 3) } else { $null }
            p95 = if ($taskServerLatencies.Count -gt 0) { [Math]::Round((Get-Percentile -Values $taskServerLatencies -Percentile 95), 3) } else { $null }
            p99 = if ($taskServerLatencies.Count -gt 0) { [Math]::Round((Get-Percentile -Values $taskServerLatencies -Percentile 99), 3) } else { $null }
            max = if ($taskServerLatencies.Count -gt 0) {
                [Math]::Round(($taskServerLatencies | Measure-Object -Maximum).Maximum, 3)
            } else {
                $null
            }
        }
        cache = [ordered]@{
            hits = $taskCacheHits
            misses = $taskCacheMisses
            hit_rate = if ($taskSuccessful.Count -gt 0) {
                [Math]::Round($taskCacheHits / [double]$taskSuccessful.Count, 6)
            } else {
                $null
            }
        }
        samples = @($Samples | ForEach-Object {
            [ordered]@{
                status_code = $_.StatusCode
                elapsed_ms = [Math]::Round($_.ElapsedMilliseconds, 3)
                cache_hit = if ($_.CacheHitKnown) { $_.CacheHit } else { $null }
                server_latency_ms = if ($_.ServerLatencyKnown) {
                    [Math]::Round($_.ServerLatencyMilliseconds, 3)
                } else {
                    $null
                }
                model_version = $_.ModelVersion
                error = $_.Error
            }
        })
    }
}

Push-Location $taskRepo
try {
    $ProgressPreference = 'SilentlyContinue'
    $taskDockerCommand = Get-Command docker -ErrorAction Stop
    $taskComposeOutput = docker compose config --format json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not resolve Docker Compose configuration.'
    }
    $taskCompose = ($taskComposeOutput -join [Environment]::NewLine) | ConvertFrom-Json
    $taskPublishedPort = $taskCompose.services.web.ports[0].published
    if (-not $taskPublishedPort) {
        throw 'The web service has no published host port.'
    }
    $taskBaseURL = 'http://127.0.0.1:' + $taskPublishedPort
    $taskRunning = @(docker compose ps --status running --services 2>&1 | Where-Object { $_ -and $_.Trim() })
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect running Compose services.'
    }
    foreach ($taskRequiredService in @('mongo', 'redis', 'api', 'web')) {
        if ($taskRunning -notcontains $taskRequiredService) {
            throw ('Required service is not running: ' + $taskRequiredService)
        }
    }

    $taskCampaignID = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $taskOutputDirectory = Join-Path $taskRepo (Join-Path 'data/api-benchmark' $taskCampaignID)
    New-Item -ItemType Directory -Force -Path $taskOutputDirectory | Out-Null
    . (Join-Path $PSScriptRoot 'session.ps1')
    $taskHeaders = Get-DemoAuthorization $taskBaseURL
    if (-not $taskHeaders.Authorization -or -not $taskHeaders.Authorization.StartsWith('Bearer ')) {
        throw 'Could not acquire an authenticated demo session.'
    }

    $taskDatasetResponse = Invoke-RestMethod ($taskBaseURL + '/api/v1/datasets/current') -Headers $taskHeaders
    $taskModelResponse = Invoke-RestMethod ($taskBaseURL + '/api/v1/models/current') -Headers $taskHeaders
    if (-not $taskModelResponse.ready -or -not $taskDatasetResponse.dataset_id) {
        throw 'A completed dataset and published model are required for API measurements.'
    }
    if ($taskModelResponse.dataset_id -ne $taskDatasetResponse.dataset_id) {
        throw 'The published model does not match the current dataset.'
    }
    $taskZones = @($taskDatasetResponse.zones | ForEach-Object { [int]$_.id })
    if ($taskZones.Count -eq 0) {
        throw 'The active dataset has no zones.'
    }
    $taskWindowMinutes = [int]$taskDatasetResponse.window_minutes
    if ($taskWindowMinutes -lt 1) {
        throw 'The active dataset has an invalid window size.'
    }
    $taskPeriodStart = ConvertTo-UtcDateTimeOffset $taskDatasetResponse.period_start
    $taskPeriodEnd = ConvertTo-UtcDateTimeOffset $taskDatasetResponse.period_end_exclusive
    $taskFirstOrigin = $taskPeriodStart.AddMinutes($taskWindowMinutes)
    $taskLastOrigin = $taskPeriodEnd.AddMinutes(-$taskWindowMinutes)
    $taskAvailableSlots = [int][Math]::Floor(($taskLastOrigin - $taskFirstOrigin).TotalMinutes / $taskWindowMinutes) + 1
    $taskAvailableQueries = [long]$taskAvailableSlots * $taskZones.Count
    if ($taskAvailableSlots -lt 1) {
        throw 'The active dataset period is too short to produce a valid prediction request.'
    }
    if (($Requests + $WarmupRequests) -gt $taskAvailableQueries) {
        throw ('Not enough distinct historical zone/interval queries for this run. Available: ' + $taskAvailableQueries)
    }

    $taskBodies = [string[]]::new($Requests)
    for ($taskIndex = 0; $taskIndex -lt $Requests; $taskIndex++) {
        $taskZoneIndex = $taskIndex % $taskZones.Count
        $taskSlot = [int][Math]::Floor($taskIndex / $taskZones.Count)
        $taskOrigin = $taskFirstOrigin.AddMinutes($taskSlot * $taskWindowMinutes)
        $taskRequest = [ordered]@{
            dataset_id = $taskDatasetResponse.dataset_id
            zone_id = $taskZones[$taskZoneIndex]
            forecast_origin = $taskOrigin.ToString('o')
            horizon_minutes = $taskWindowMinutes
        }
        $taskBodies[$taskIndex] = $taskRequest | ConvertTo-Json -Compress
    }

    $taskTypeName = 'HttpLoadRunner' + [Guid]::NewGuid().ToString('N')
    $taskTypeDefinition = @"
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

public sealed class ApiBenchmarkSample
{
    public int StatusCode { get; set; }
    public double ElapsedMilliseconds { get; set; }
    public bool CacheHit { get; set; }
    public bool CacheHitKnown { get; set; }
    public double ServerLatencyMilliseconds { get; set; }
    public bool ServerLatencyKnown { get; set; }
    public string ModelVersion { get; set; }
    public string Error { get; set; }
}

    namespace ApiBenchmark
{
    public static class $taskTypeName
    {
        public static ApiBenchmarkSample[] Run(string url, string token, string[] bodies, int concurrency, int timeoutSeconds)
        {
            ServicePointManager.DefaultConnectionLimit = Math.Max(ServicePointManager.DefaultConnectionLimit, concurrency);
            var samples = new ApiBenchmarkSample[bodies.Length];
            var nextIndex = -1;
            using (var handler = new HttpClientHandler())
            {
                handler.MaxConnectionsPerServer = concurrency;
                using (var client = new HttpClient(handler))
                {
                    client.Timeout = TimeSpan.FromSeconds(timeoutSeconds);
                    client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
                    var workers = new Task[concurrency];
                    for (var worker = 0; worker < concurrency; worker++)
                    {
                        workers[worker] = Task.Run(() =>
                        {
                            while (true)
                            {
                                var index = Interlocked.Increment(ref nextIndex);
                                if (index >= bodies.Length)
                                    return;
                                var sample = new ApiBenchmarkSample();
                                var clock = Stopwatch.StartNew();
                                try
                                {
                                    using (var request = new HttpRequestMessage(HttpMethod.Post, url))
                                    {
                                        request.Content = new StringContent(bodies[index], System.Text.Encoding.UTF8, "application/json");
                                        using (var response = client.SendAsync(request).GetAwaiter().GetResult())
                                        {
                                            sample.StatusCode = (int)response.StatusCode;
                                            var content = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                                            var cache = Regex.Match(content, "\"cache_hit\"\\s*:\\s*(true|false)", RegexOptions.IgnoreCase);
                                            if (cache.Success)
                                            {
                                                sample.CacheHit = String.Equals(cache.Groups[1].Value, "true", StringComparison.OrdinalIgnoreCase);
                                                sample.CacheHitKnown = true;
                                            }
                                            var latency = Regex.Match(content, "\"latency_ms\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)", RegexOptions.CultureInvariant);
                                            if (latency.Success)
                                            {
                                                double value;
                                                if (Double.TryParse(latency.Groups[1].Value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out value))
                                                {
                                                    sample.ServerLatencyMilliseconds = value;
                                                    sample.ServerLatencyKnown = true;
                                                }
                                            }
                                            var version = Regex.Match(content, "\"model_version\"\\s*:\\s*\"([^\"]+)\"");
                                            if (version.Success)
                                                sample.ModelVersion = version.Groups[1].Value;
                                            if ((int)response.StatusCode != 200)
                                                sample.Error = "http_" + (int)response.StatusCode;
                                            else if (!sample.CacheHitKnown || !sample.ServerLatencyKnown || String.IsNullOrEmpty(sample.ModelVersion))
                                                sample.Error = "invalid_prediction_response";
                                        }
                                    }
                                }
                                catch (Exception ex)
                                {
                                    sample.Error = ex.GetType().Name;
                                }
                                finally
                                {
                                    clock.Stop();
                                    sample.ElapsedMilliseconds = clock.Elapsed.TotalMilliseconds;
                                    samples[index] = sample;
                                }
                            }
                        });
                    }
                    Task.WaitAll(workers);
                }
            }
            return samples;
    }
}
}
"@
    $taskHttpRunnerType = Add-Type -TypeDefinition $taskTypeDefinition -ReferencedAssemblies 'System.Net.Http' -PassThru |
        Where-Object { $_.Name -eq $taskTypeName } |
        Select-Object -First 1
    if (-not $taskHttpRunnerType) {
        throw 'Could not compile the API benchmark HTTP load runner.'
    }

    if ($WarmupRequests -gt 0) {
        $taskWarmupBodies = [string[]]::new($WarmupRequests)
        for ($taskIndex = 0; $taskIndex -lt $WarmupRequests; $taskIndex++) {
            $taskAbsoluteIndex = $Requests + $taskIndex
            $taskZoneIndex = $taskAbsoluteIndex % $taskZones.Count
            $taskSlot = [int][Math]::Floor($taskAbsoluteIndex / $taskZones.Count)
            $taskOrigin = $taskFirstOrigin.AddMinutes($taskSlot * $taskWindowMinutes)
            $taskWarmupRequest = [ordered]@{
                dataset_id = $taskDatasetResponse.dataset_id
                zone_id = $taskZones[$taskZoneIndex]
                forecast_origin = $taskOrigin.ToString('o')
                horizon_minutes = $taskWindowMinutes
            }
            $taskWarmupBodies[$taskIndex] = $taskWarmupRequest | ConvertTo-Json -Compress
        }
    }

    $taskToken = $taskHeaders.Authorization.Substring('Bearer '.Length)
    if ($WarmupRequests -gt 0) {
        $taskWarmupClock = [Diagnostics.Stopwatch]::StartNew()
        $taskWarmupSamples = $taskHttpRunnerType.GetMethod('Run').Invoke(
            $null,
            @($taskBaseURL + '/api/v1/predictions', $taskToken, $taskWarmupBodies, $Concurrency, $TimeoutSeconds)
        )
        $taskWarmupClock.Stop()
        $taskWarmupFailed = @($taskWarmupSamples | Where-Object {
            $_.StatusCode -ne 200 -or $_.ModelVersion -ne $taskModelResponse.version
        })
        if ($taskWarmupFailed.Count -gt 0) {
            throw ('API warmup failed for ' + $taskWarmupFailed.Count + ' of ' + $WarmupRequests + ' requests.')
        }
    }

    $taskPhaseResults = @()
    foreach ($taskPhase in @('initial_pass', 'replay_pass')) {
        $taskPhaseClock = [Diagnostics.Stopwatch]::StartNew()
        $taskSamples = $taskHttpRunnerType.GetMethod('Run').Invoke(
            $null,
            @($taskBaseURL + '/api/v1/predictions', $taskToken, $taskBodies, $Concurrency, $TimeoutSeconds)
        )
        $taskPhaseClock.Stop()
        $taskSummary = Get-PassSummary -Name $taskPhase -Samples $taskSamples `
            -ElapsedSeconds $taskPhaseClock.Elapsed.TotalSeconds `
            -ExpectedModelVersion $taskModelResponse.version
        $taskPhaseResults += [pscustomobject]$taskSummary
        Write-Host ($taskPhase + ': p95=' + $taskSummary.http_latency_ms.p95 + ' ms; errors=' + $taskSummary.errors + '; cache hits=' + $taskSummary.cache.hits)
    }

    $taskReport = [ordered]@{
        campaign_id = $taskCampaignID
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        status = if (@($taskPhaseResults | Where-Object { $_.errors -gt 0 }).Count -eq 0) { 'complete' } else { 'completed_with_errors' }
        git = [ordered]@{
            commit = (git rev-parse HEAD 2>&1) -join ''
            branch = (git branch --show-current 2>&1) -join ''
            worktree_dirty = @(git status --porcelain 2>&1).Count -gt 0
        }
        target = [ordered]@{
            base_url = $taskBaseURL
            route = 'POST /api/v1/predictions'
            authenticated = $true
            concurrency = $Concurrency
            timeout_seconds = $TimeoutSeconds
        }
        dataset = [ordered]@{
            dataset_id = $taskDatasetResponse.dataset_id
            zone_count = $taskZones.Count
            window_minutes = $taskWindowMinutes
            model_version = $taskModelResponse.version
        }
        workload = [ordered]@{
            requests_per_phase = $Requests
            warmup_requests = $WarmupRequests
            unique_queries_per_phase = $Requests
            same_query_set_replayed = $true
        }
        warmup = if ($WarmupRequests -gt 0) {
            [ordered]@{
                requests = $WarmupRequests
                elapsed_seconds = [Math]::Round($taskWarmupClock.Elapsed.TotalSeconds, 6)
                failures = @($taskWarmupSamples | Where-Object { $_.StatusCode -ne 200 }).Count
            }
        } else {
            $null
        }
        phases = @($taskPhaseResults)
        interpretation = 'HTTP latency is measured by this client through the local web proxy; server_latency_ms is reported by the Go API. initial_pass does not guarantee cold cache because identical queries may already exist in Redis. Cache hits and misses are measured, not assumed.'
        output = 'Per-request samples are included in this local report. Authentication tokens and request bodies are not recorded.'
    }
    $taskReportPath = Join-Path $taskOutputDirectory 'report.json'
    [IO.File]::WriteAllText(
        $taskReportPath,
        ($taskReport | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    )
    Write-Host ('API benchmark report: ' + $taskReportPath)
    if ($taskReport.status -ne 'complete') {
        throw ('API benchmark completed with request errors. Inspect ' + $taskReportPath)
    }
} finally {
    $ProgressPreference = $taskPreviousProgressPreference
    Pop-Location
}
