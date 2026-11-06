#Requires -Version 7.2
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/benchmark/common.psm1') -Force -DisableNameChecking
$config=Get-BenchConfiguration 'configs/benchmark-api.json'
$plan=@(New-BenchPlan $config 'test-api-phase')
if($plan.Count -ne 27 -or @($plan|Where-Object kind -ne api).Count){throw 'API phase changed the official 27-pass matrix.'}
$campaign='test-api-evidence-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$dir=Resolve-BenchPath "bench/raw/$campaign"
$file=Join-Path $dir 'requests.json'
$context=@{scope='real';raw_dir=$dir}
$p=@{parameters=@{requests=4;cache='warm';concurrency=10}}
$raw=@{dataset_id='ds';model_version='v1';scenario='warm';concurrency=10;elapsed_seconds=1.0;error_counts=@{unexpected_cache_state=1};error_latencies_ms=@(55.0);samples=@(
    @{index=0;success=$true;http_status=200;timeout=$false;cache_hit=$true;latency_ms=1.0},
    @{index=1;success=$true;http_status=200;timeout=$false;cache_hit=$true;latency_ms=2.0},
    @{index=2;success=$true;http_status=200;timeout=$false;cache_hit=$true;latency_ms=3.0},
    @{index=3;success=$false;http_status=200;timeout=$false;cache_hit=$false;latency_ms=55.0;error='unexpected_cache_state'}
)}
Write-BenchJson $file $raw
$metrics=@{requests_path=[IO.Path]::GetRelativePath((Get-BenchRoot),$file).Replace('\','/');requests_sha256=(Get-FileHash $file).Hash.ToLowerInvariant();model_version='v1';throughput_total=4;throughput_success=3;proportion_under_100_ms=.75;cache_hits=3;errors=1;succeeded=3;timeouts=0;p50_ms=2;p95_ms=55;p99_ms=55;max_ms=55;error_counts=@{unexpected_cache_state=1};error_latencies_ms=@(55.0)}
$result=@{dataset=@{id='ds'};metrics=$metrics}
Assert-BenchAPIEvidence $context $p $result
$checks=2
foreach($bad in @('hide-error','hide-reason','hide-error-latency','wrong-percentile','wrong-throughput')){
    $original=ConvertFrom-BenchJsonData ($metrics|ConvertTo-Json -Depth 20)
    switch($bad){
        'hide-error' {$metrics.errors=0}
        'hide-reason' {$metrics.error_counts=@{}}
        'hide-error-latency' {$metrics.error_latencies_ms=@()}
        'wrong-percentile' {$metrics.p95_ms=3}
        'wrong-throughput' {$metrics.throughput_success=4}
    }
    $rejected=$false
    try{Assert-BenchAPIEvidence $context $p $result}catch{$rejected=$true}
    if(-not $rejected){throw "Accepted manipulated evidence: $bad"};$checks++
    $metrics=$original;$result.metrics=$metrics
}
Write-Output "PASS: $checks checks; unfavorable API outcomes remain visible and manipulated aggregates are rejected. Synthetic evidence only."
