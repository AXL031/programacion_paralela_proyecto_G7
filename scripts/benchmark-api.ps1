#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ContextPath,[Parameter(Mandatory)][string]$SamplePath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'benchmark/common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'benchmark/workload.psm1') -DisableNameChecking
$work=Open-BenchWorkload $ContextPath $SamplePath $OutputPath 'api'
$c=$work.context; $s=$work.sample
$started=[datetime]::UtcNow
$collector=$null; $headers=$null; $redisStopped=$false
try {
    $headers=New-BenchSession $c
    $m=Get-BenchCurrentDataset $c $s.sample_id
    $up=Invoke-BenchCompose $c @('up','-d','--no-build','--no-deps','--wait','redis') "logs/$($s.sample_id)-redis-up" 60
    Assert-BenchSuccess $up 'Restore isolated Redis before preparation'
    $flush=Invoke-BenchCompose $c @('exec','-T','redis','redis-cli','FLUSHDB') "logs/$($s.sample_id)-redis-flush" 30
    Assert-BenchSuccess $flush 'Flush isolated benchmark Redis'
    if($flush.stdout.Trim() -ne 'OK'){throw 'Redis did not confirm FLUSHDB.'}
    if($s.parameters.cache -eq 'unavailable'){
        $stop=Invoke-BenchCompose $c @('stop','redis') "logs/$($s.sample_id)-redis-stop" 60
        Assert-BenchSuccess $stop 'Stop isolated benchmark Redis';$redisStopped=$true
        $ready=Invoke-RestMethod ($c.api_url+'/health/ready') -TimeoutSec 10
        if($ready.redis -or -not $ready.mongo){throw 'Redis outage was not observed by the API.'}
    } else {
        $ready=Invoke-RestMethod ($c.api_url+'/health/ready') -TimeoutSec 10
        if(-not $ready.redis){throw 'API cannot reach isolated Redis.'}
    }
    $collector=Start-BenchResourceCollector $c $s $SamplePath
    # Process coverage preparation is outside the client's measurement window.
    Start-Sleep -Seconds 5
    $dataOutput=Join-Path $c.data_dir "api/$($s.sample_id).json"
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dataOutput))
    $clientArgs=@('--profile','jobs','run','-T','--rm','--no-deps','benchmark-api','-base-url','http://api:8080','-cache',[string]$s.parameters.cache,'-requests',[string]$s.parameters.requests,'-concurrency',[string]$s.parameters.concurrency,'-output',"data/api/$($s.sample_id).json")
    $call=Invoke-BenchCompose $c $clientArgs "logs/$($s.sample_id)-client" 180
    Start-Sleep -Seconds 3
    $resourcePath=$collector.output
    $capture=Stop-BenchResourceCollector $collector;$collector=$null
    $resources=Get-BenchResourcesEvidence $c $s $resourcePath $capture
    if(Test-Path -LiteralPath $dataOutput){
        $rawPath=Join-Path $c.raw_dir "api/$($s.sample_id).json"
        Write-BenchJson $rawPath (Read-BenchJson $dataOutput)
    }
    Assert-BenchSuccess $call 'HTTP measured pass'
    if($resources.errors.Count){throw ($resources.errors -join '; ')}
    $report=Read-BenchJson $dataOutput
    if($report.dataset_id -cne $m.dataset_id -or $report.attempted -ne $s.parameters.requests -or $report.completed -ne $report.attempted){throw 'HTTP workload identity/count mismatch.'}
}catch{
    Write-BenchJson (Join-Path $c.raw_dir "failures/$($s.sample_id).json") @{sample_id=$s.sample_id;error=(Protect-BenchText $_.Exception.Message);at=[datetime]::UtcNow.ToString('o')}
    throw
}finally{
    if($collector){[void](Stop-BenchResourceCollector $collector)}
    if($redisStopped){
        $restore=Invoke-BenchCompose $c @('up','-d','--no-build','--no-deps','--wait','redis') "logs/$($s.sample_id)-redis-restore" 60
        Assert-BenchSuccess $restore 'Restore isolated Redis after outage'
    }
    if($headers){Close-BenchSession $c $headers}
}
$ready=Invoke-RestMethod ($c.api_url+'/health/ready') -TimeoutSec 10
if(-not $ready.redis){throw 'Redis restoration did not reach the API.'}
$metrics=@{}
foreach($key in @('attempted','completed','succeeded','errors','timeouts','cache_hits','p50_ms','p95_ms','p99_ms','max_ms','elapsed_seconds','throughput_total','throughput_success','proportion_under_100_ms','objective_met','error_counts','error_latencies_ms','model_version','concurrency','load_model')){$metrics[$key]=$report[$key]}
$metrics.requests_path=Get-BenchRelativePath $rawPath
$metrics.requests_sha256=Get-BenchSHA256 $rawPath
$metrics.cache_scenario=$s.parameters.cache
$metrics.measurement_complete=$true
$metrics.operational_outcome=$(if($report.objective_met){'target_met'}else{'target_not_met'})
$metrics.route='direct isolated REST; in-container client'
$timings=@{preparation_seconds=$null;compute_seconds=$report.elapsed_seconds;evaluation_seconds=$null;publication_seconds=$null;total_seconds=$report.elapsed_seconds}
$result=New-BenchWorkloadResult $c $s $started (Get-BenchDatasetIdentity $m) $timings $resources.summary $metrics
$result.checks.redis_restored=$true
$result.checks.cache_preparation_verified=$true
Write-BenchJson $OutputPath $result
[void](Assert-BenchSample $c $s $OutputPath)
