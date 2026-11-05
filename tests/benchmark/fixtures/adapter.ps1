# Synthetic orchestration fixture only. Never a real benchmark implementation.
#Requires -Version 7.2
param([Parameter(Mandatory)][string]$ContextPath, [Parameter(Mandatory)][string]$OutputPath, [string]$SamplePath, [string]$ManifestPath)
$ErrorActionPreference = 'Stop'
$context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json -AsHashtable
if ($context.scope -ne 'orchestrator_fixture') { throw 'The test adapter cannot produce real evidence.' }
$behavior = if ($context.config.ContainsKey('fixture_behavior')) { $context.config.fixture_behavior } else { 'normal' }
if ($behavior -eq 'exit') { [Console]::Error.WriteLine('Deliberate fixture failure'); exit 7 }
if ($behavior -eq 'no-output') { exit 0 }
if ($behavior -eq 'timeout') { Start-Sleep -Seconds 10 }
if ($ManifestPath) {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
    $ids = @($manifest.samples.sample_id)
    if ($behavior -eq 'partial-summary') { $ids = @($ids | Select-Object -Skip 1) }
    $output = @{ schema_version = 'benchmark-v1'; campaign_id = $context.campaign_id; scope = $context.scope; status = 'passed'; sample_ids = $ids; synthetic = $true }
} else {
    $sample = Get-Content -LiteralPath $SamplePath -Raw | ConvertFrom-Json -AsHashtable
    $metrics = switch ($sample.kind) {
        'load' { @{ reused = $false; read = 8; accepted = 3; rejected = 4; outside_period = 1; persisted = 3 } }
        'training' {
            $workers = @(); $tasks = @{}
            if ($sample.parameters.mode -eq 'distributed') {
                foreach ($n in 1..$sample.parameters.workers) { $workers += "fixture-worker-$n"; $tasks["fixture-worker-$n"] = 2 }
            }
            @{ workers = $workers; tasks_by_worker = $tasks; candidate_max_difference = 0; model_version = 'synthetic-model' }
        }
        'api' {
            $hits = if ($sample.parameters.cache -eq 'warm') { $sample.parameters.requests } else { 0 }
            @{ attempted = $sample.parameters.requests; completed = $sample.parameters.requests; errors = 0; cache_hits = $hits; p50_ms = 1; p95_ms = 2; p99_ms = 3; max_ms = 4; objective_met = $true }
        }
    }
    $output = @{
        schema_version = 'benchmark-v1'; campaign_id = $context.campaign_id; scope = $context.scope
        sample_id = $sample.sample_id; case_id = $sample.case_id; kind = $sample.kind; repetition = $sample.repetition; warmup = $sample.warmup
        started_at = [datetime]::UtcNow.AddMilliseconds(-10).ToString('o'); completed_at = [datetime]::UtcNow.ToString('o')
        status = 'passed'; errors = @()
        dataset = @{ id = 'synthetic-dataset'; load_id = 'synthetic-load'; snapshot_sha256 = ('0' * 64); source_sha256 = ('1' * 64); catalog_sha256 = ('2' * 64) }
        timings = @{ preparation_seconds = $null; compute_seconds = 0.001; evaluation_seconds = $null; publication_seconds = $null; total_seconds = 0.01 }
        resources = @{ status = 'synthetic'; path = $null; sha256 = $null; valid_samples = 1; missing_samples = 0 }
        checks = @{ dataset_verified = $true; result_valid = $true; resources_valid = $true; snapshot_equivalent = $true; candidate_equivalent = $true }
        metrics = $metrics
    }
    if ($behavior -eq 'mismatch') { $output.campaign_id = 'different-campaign' }
    if ($behavior -eq 'real-scope') { $output.scope = 'real' }
    if ($behavior -eq 'reused' -and $sample.kind -eq 'load') { $output.metrics.reused = $true }
    if ($behavior -eq 'bad-check') { $output.checks.result_valid = $false }
    if ($behavior -eq 'bad-cache' -and $sample.kind -eq 'api') { $output.metrics.cache_hits = -1 }
}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath))
[IO.File]::WriteAllText($OutputPath, ($output | ConvertTo-Json -Depth 20))
Write-Output 'Synthetic orchestration fixture; not performance evidence.'
