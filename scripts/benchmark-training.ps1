#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ContextPath,[Parameter(Mandatory)][string]$SamplePath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'benchmark/common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'benchmark/workload.psm1') -DisableNameChecking
$work=Open-BenchWorkload $ContextPath $SamplePath $OutputPath 'training'
$c=$work.context; $s=$work.sample
$collector=$null; $headers=$null
$started=[datetime]::UtcNow
try {
    $headers=New-BenchSession $c
    $cluster=Invoke-RestMethod ($c.api_url+'/api/v1/cluster') -Headers $headers -TimeoutSec 10
    if($cluster.active_run){throw 'Another training run is active.'}
    $m=Get-BenchCurrentDataset $c $s.sample_id
    $referenceHost=Join-Path $c.data_dir 'benchmark/reference-S.json'
    $referenceRaw=Join-Path $c.raw_dir 'reference/sequential-diagnostics.json'
    if(-not(Test-Path -LiteralPath $referenceHost)){
        $referenceCall=Invoke-BenchCompose $c @('--profile','jobs','run','-T','--rm','--no-deps','trainer','-mode','sequential','-config','data/configs/training.json','-diagnostics','data/benchmark/reference-S.json','-sample-id','reference-S') 'logs/reference-S-trainer'
        Assert-BenchSuccess $referenceCall 'Auxiliary sequential reference (excluded from measurements)'
        Write-BenchJson $referenceRaw (Read-BenchJson $referenceHost)
    }
    $n=[int]$s.parameters.workers
    if($s.parameters.mode -eq 'distributed'){
        $scale=Invoke-BenchCompose $c @('up','-d','--no-build','--no-deps','--scale',"worker=$n",'worker') "logs/$($s.sample_id)-scale" 120
        Assert-BenchSuccess $scale 'Scale isolated workers'
        $deadline=[datetime]::UtcNow.AddSeconds(40)
        do {
            $cluster=Invoke-RestMethod ($c.api_url+'/api/v1/cluster') -Headers $headers -TimeoutSec 10
            if(@($cluster.workers).Count -eq $n -and @($cluster.workers|Where-Object busy).Count -eq 0){break}
            Start-Sleep -Milliseconds 500
        }while([datetime]::UtcNow -lt $deadline)
        if(@($cluster.workers).Count -ne $n -or $cluster.active_run){throw 'Exact idle worker count was not achieved.'}
    } else {
        $stop=Invoke-BenchCompose $c @('stop','worker') "logs/$($s.sample_id)-stop-idle-workers" 60
        Assert-BenchSuccess $stop 'Stop isolated idle workers for sequential case'
    }
    $cfg=Read-BenchJson (Join-Path $c.data_dir 'configs/training.json')
    $cfg.workers=$n
    $configRelative="data/configs/$($s.sample_id)-training.json"
    Write-BenchJson (Join-Path $c.data_dir "configs/$($s.sample_id)-training.json") $cfg
    $args=@('--profile','jobs','run','-T','--rm','--no-deps','trainer','-mode',[string]$s.parameters.mode,'-config',$configRelative,'-diagnostics',"data/benchmark/$($s.sample_id).json",'-sample-id',[string]$s.sample_id)
    if($s.parameters.mode -eq 'distributed'){$args+=@('-reference-diagnostics','data/benchmark/reference-S.json')}
    $collector=Start-BenchResourceCollector $c $s $SamplePath
    $call=Invoke-BenchCompose $c $args "logs/$($s.sample_id)-trainer"
    $resourcePath=$collector.output
    $capture=Stop-BenchResourceCollector $collector; $collector=$null
    $resources=Get-BenchResourcesEvidence $c $s $resourcePath $capture
    Assert-BenchSuccess $call 'Training sample'
    if($resources.errors.Count){throw ($resources.errors -join '; ')}
    $trained=ConvertFrom-BenchJsonData $call.stdout
    $r=$trained.run; $a=$trained.artifact
    if($r.status -ne 'completed' -or $a.dataset_id -ne $m.dataset_id -or $a.snapshot_sha256 -ne $m.snapshot.sha256){throw 'Training identity/status mismatch.'}
    $diagRaw=Join-Path $c.raw_dir "diagnostics/$($s.sample_id).json"
    Write-BenchJson $diagRaw (Read-BenchJson (Join-Path $c.data_dir "benchmark/$($s.sample_id).json"))
    $metrics=@{
        workers=@($r.workers); tasks_by_worker=$r.tasks_by_worker; model_version=$a.version; run_id=$r.run_id
        candidate_max_difference=$trained.diagnostics.candidate_max_difference
        candidate_diagnostics_path=(Get-BenchRelativePath $diagRaw); candidate_diagnostics_sha256=(Get-BenchSHA256 $diagRaw)
        reference_diagnostics_path=(Get-BenchRelativePath $referenceRaw); reference_diagnostics_sha256=(Get-BenchSHA256 $referenceRaw)
        published_weights=$a.weights; selection=$a.selection; config=$r.config
        timing_scope='in-process run through publication; container/adapter startup excluded'
    }
    $timings=@{preparation_seconds=$r.preparation_seconds;compute_seconds=$r.training_seconds;evaluation_seconds=$r.evaluation_seconds;publication_seconds=$r.publication_seconds;total_seconds=$r.total_seconds}
    $result=New-BenchWorkloadResult $c $s $started (Get-BenchDatasetIdentity $m) $timings $resources.summary $metrics
    $result.checks.candidate_equivalent=$true
    Write-BenchJson $OutputPath $result
    [void](Assert-BenchSample $c $s $OutputPath)
}catch{
    Write-BenchJson (Join-Path $c.raw_dir "failures/$($s.sample_id).json") @{sample_id=$s.sample_id;error=(Protect-BenchText $_.Exception.Message);at=[datetime]::UtcNow.ToString('o')}
    throw
}finally{
    if($collector){[void](Stop-BenchResourceCollector $collector)}
    if($headers){Close-BenchSession $c $headers}
}
