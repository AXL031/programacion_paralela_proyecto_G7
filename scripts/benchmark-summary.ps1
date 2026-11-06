#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContextPath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'benchmark/common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'benchmark/statistics.psm1') -Force -DisableNameChecking
$context = Read-BenchJson $ContextPath
Assert-BenchOwnership $context
$manifestFile = Resolve-BenchPath (Resolve-BenchPath $ManifestPath) $context.results_dir
$output = Resolve-BenchPath (Resolve-BenchPath $OutputPath) $context.results_dir
if ($output -eq $manifestFile -or [IO.Path]::GetDirectoryName($output) -ne $context.results_dir -or
    [IO.Path]::GetFileName($output) -ne 'summary.json') { throw 'Summary output must be the campaign summary.json.' }
$manifest = Read-BenchJson $manifestFile
foreach ($key in @('schema_version', 'campaign_id', 'scope', 'project')) {
    if ($manifest[$key] -cne $context[$key]) { throw "Manifest/context mismatch: $key" }
}
$archived = Read-BenchJson (Join-Path $context.results_dir 'config.json')
if ((ConvertTo-BenchCanonicalJson $archived) -cne (ConvertTo-BenchCanonicalJson $context.config)) { throw 'Archived configuration differs from context.' }
$plan = @(Read-BenchJson (Join-Path $context.results_dir 'plan.json'))
$expected = @(New-BenchPlan $context.config $context.campaign_id)
if ((ConvertTo-BenchCanonicalJson $expected) -cne (ConvertTo-BenchCanonicalJson $plan)) { throw 'Plan differs from campaign protocol.' }
$records = @($manifest.samples)
if ($records.Count -ne $plan.Count -or @($records.sample_id | Select-Object -Unique).Count -ne $plan.Count -or
    (@($records.sample_id | Sort-Object) -join ',') -cne (@($plan.sample_id | Sort-Object) -join ',') -or
    @($records | Where-Object state -NE 'passed').Count -or @($manifest.errors).Count) { throw 'Incomplete, duplicated or failed campaign.' }
$results = [Collections.Generic.List[object]]::new()
$resourceTables = [Collections.Generic.List[object]]::new()
$dataset = $null
foreach ($item in $plan) {
    $record = $records | Where-Object sample_id -CEQ $item.sample_id
    $file = Resolve-BenchPath (Resolve-BenchPath $record.result) $context.results_dir
    $result = Assert-BenchSample $context $item $file
    if ($null -eq $dataset) { $dataset = $result.dataset }
    foreach ($key in @('id', 'snapshot_sha256', 'source_sha256', 'catalog_sha256')) {
        if ($dataset[$key] -cne $result.dataset[$key]) { throw "Incompatible dataset: $key" }
    }
    if ($result.kind -eq 'training') {
        foreach ($phase in @('compute_seconds', 'total_seconds')) { Assert-BenchNumber $result.timings[$phase] -Positive }
    }
    if ($context.scope -eq 'real') {
        $observations = @([IO.File]::ReadLines((Resolve-BenchPath $result.resources.path)) | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $resourceTables.Add(@{ sample_id = $result.sample_id; warmup = $result.warmup; summary = (Get-BenchResourceSummary $observations) })
    }
    $results.Add($result)
}
$timings = [Collections.Generic.List[object]]::new()
$api = [Collections.Generic.List[object]]::new()
foreach ($case in @($results.case_id | Sort-Object -Unique)) {
    $measured = @($results | Where-Object { $_.case_id -ceq $case -and -not $_.warmup })
    if (-not $measured.Count) { throw "Case has no measured repetitions: $case" }
    foreach ($phase in @('preparation_seconds', 'compute_seconds', 'evaluation_seconds', 'publication_seconds', 'total_seconds')) {
        $values = @($measured | ForEach-Object { $_.timings[$phase] } | Where-Object { $null -ne $_ })
        $timings.Add([ordered]@{
            case_id = $case; kind = $measured[0].kind; phase = $phase; unit = 'seconds'; missing = $measured.Count - $values.Count
            statistics = $(if ($values.Count -eq $measured.Count) { Get-BenchStatistics $values } else { $null })
        })
    }
    if ($measured[0].kind -eq 'api') {
        foreach ($metric in @('p50_ms', 'p95_ms', 'p99_ms', 'max_ms', 'errors', 'cache_hits','throughput_total','throughput_success','proportion_under_100_ms')) {
            if(-not $measured[0].metrics.Contains($metric)){continue}
            $api.Add([ordered]@{ case_id = $case; metric = $metric; statistics = (Get-BenchStatistics @($measured | ForEach-Object { $_.metrics[$metric] })) })
        }
    }
}
$speedups = [Collections.Generic.List[object]]::new()
foreach ($phase in @('compute_seconds', 'total_seconds')) {
    $s = @($timings | Where-Object { $_.case_id -ceq 'S' -and $_.phase -eq $phase })
    $d1 = @($timings | Where-Object { $_.case_id -ceq 'D1' -and $_.phase -eq $phase })
    if($context.config.Contains('phase') -and $context.config.phase -eq 'api'){continue}
    if ($s.Count -ne 1 -or $d1.Count -ne 1) { throw 'Sequential/D1 baselines required.' }
    foreach ($n in $context.config.protocol.training_workers) {
        $dn = $timings | Where-Object { $_.case_id -ceq "D$n" -and $_.phase -eq $phase }
        $ratios = Get-BenchSpeedup $s[0].statistics.median $d1[0].statistics.median $dn.statistics.median $n
        $speedups.Add([ordered]@{ case_id = "D$n"; workers = $n; phase = $phase; ratios = $ratios })
    }
}
$limitations = @(
    'Arithmetic observation means; sample standard deviation uses n-1 (null for n=1).',
    'Warmups are identified in sample_ids and resource evidence but excluded from timing/statistical comparisons.',
    'API percentiles are per-pass summaries; their medians are not pooled request percentiles.',
    'Resources cover the collector lifetime; totals include only observations aligned within 250 ms and never mix process/container scopes.',
    'Observed RAM maxima depend on sampling coverage; no aligned observations means a null total.',
    'One host with containers does not establish scalability between physical servers.'
)
if ($context.scope -ne 'real') { $limitations += 'SYNTHETIC FIXTURE: no real performance or resource claims.' }
Write-BenchJson $output ([ordered]@{
    schema_version = 'benchmark-v1'; campaign_id = $context.campaign_id; scope = $context.scope; status = 'passed'
    sample_ids = @($plan.sample_id); excluded_warmup_ids = @($plan | Where-Object warmup | ForEach-Object sample_id)
    dataset = $dataset; timings = @($timings.ToArray()); speedups = @($speedups.ToArray())
    api = @($api.ToArray()); resources = @($resourceTables.ToArray()); limitations = $limitations
    api_target_not_met_sample_ids = @($results | Where-Object {$_.kind -eq 'api' -and -not $_.metrics.objective_met} | ForEach-Object sample_id)
})
$csv = @($timings | ForEach-Object {
    $stats = if ($null -ne $_.statistics) { $_.statistics } else { @{ mean = $null; median = $null; min = $null; max = $null; sample_stddev = $null } }
    [pscustomobject]@{ case_id = $_.case_id; kind = $_.kind; phase = $_.phase; unit = $_.unit; missing = $_.missing
        count = $(if ($null -ne $_.statistics) { $_.statistics.count } else { 0 })
        mean = $stats.mean; median = $stats.median; min = $stats.min; max = $stats.max; sample_stddev = $stats.sample_stddev }
})
$csv | Export-Csv -LiteralPath (Join-Path $context.results_dir 'summary-timings.csv') -NoTypeInformation -Encoding utf8
$speedups | ForEach-Object {
    [pscustomobject]@{ case_id = $_.case_id; workers = $_.workers; phase = $_.phase
        speedup_vs_sequential = $_.ratios.speedup_vs_sequential; speedup_vs_d1 = $_.ratios.speedup_vs_d1; efficiency_vs_d1 = $_.ratios.efficiency_vs_d1 }
} | Export-Csv -LiteralPath (Join-Path $context.results_dir 'summary-speedups.csv') -NoTypeInformation -Encoding utf8
$resourceCSV=foreach($sampleResource in $resourceTables){
    foreach($service in $sampleResource.summary.services){
        [pscustomobject]@{sample_id=$sampleResource.sample_id;warmup=$sampleResource.warmup;service=$service.service;scope=$service.scope;valid_samples=$service.valid_samples;missing_samples=$service.missing_samples;cpu_mean=$(if($service.cpu_percent){$service.cpu_percent.mean}else{$null});cpu_max=$(if($service.cpu_percent){$service.cpu_percent.max}else{$null});max_memory_bytes=$service.max_memory_bytes}
    }
}
@($resourceCSV)|Export-Csv -LiteralPath (Join-Path $context.results_dir 'summary-resources.csv') -NoTypeInformation -Encoding utf8
$resourceTotals=foreach($sampleResource in $resourceTables){
    foreach($total in $sampleResource.summary.totals){
        [pscustomobject]@{sample_id=$sampleResource.sample_id;warmup=$sampleResource.warmup;scope=$total.scope;aligned_samples=$total.aligned_samples;max_skew_seconds=$total.max_skew_seconds;cpu_mean=$(if($total.cpu_percent){$total.cpu_percent.mean}else{$null});cpu_max=$(if($total.cpu_percent){$total.cpu_percent.max}else{$null});max_memory_bytes=$total.max_memory_bytes}
    }
}
@($resourceTotals)|Export-Csv -LiteralPath (Join-Path $context.results_dir 'summary-resource-totals.csv') -NoTypeInformation -Encoding utf8
$apiCSV=foreach($result in $results|Where-Object kind -EQ 'api'){
    $metrics=$result.metrics
    [pscustomobject]@{sample_id=$result.sample_id;case_id=$result.case_id;requests=$metrics.attempted;errors=$metrics.errors;cache_hits=$metrics.cache_hits;p50_ms=$metrics.p50_ms;p95_ms=$metrics.p95_ms;p99_ms=$metrics.p99_ms;max_ms=$metrics.max_ms;objective_met=$metrics.objective_met;throughput_success=$(if($metrics.Contains('throughput_success')){$metrics.throughput_success}else{$null});proportion_under_100_ms=$(if($metrics.Contains('proportion_under_100_ms')){$metrics.proportion_under_100_ms}else{$null})}
}
@($apiCSV)|Export-Csv -LiteralPath (Join-Path $context.results_dir 'summary-api.csv') -NoTypeInformation -Encoding utf8
