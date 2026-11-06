#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Campaign)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'benchmark/common.psm1') -DisableNameChecking
$c=Initialize-BenchCampaign $Campaign 'configs/benchmark-api.json'
Assert-BenchOwnership $c
if($c.config.phase -ne 'api'){throw 'Bootstrap is exclusively for the separate API matrix.'}
$mutex=[Threading.Mutex]::new($false,'TransporteG7BenchmarkHostV1')
$locked=$false
try{
    $locked=$mutex.WaitOne(0);if(-not $locked){throw 'Another benchmark operation holds the host lock.'}
    $record=Join-Path $c.results_dir 'bootstrap.json'
    if(Test-Path -LiteralPath $record){throw 'Bootstrap already recorded; use a new campaign.'}
    $resolved=Assert-BenchCompose $c
    Assert-BenchExistingResources $c $resolved
    $load=Invoke-BenchCompose $c @('--profile','jobs','run','-T','--rm','--no-deps','loader','-config','data/configs/loader.json','-workers','4','-require-fresh') 'bootstrap/loader' 180
    Assert-BenchSuccess $load 'Unmeasured isolated dataset preparation'
    $loaded=ConvertFrom-BenchJsonData $load.stdout
    if($loaded.reused -or $loaded.manifest.stats.accepted -le 1000000){throw 'Invalid bootstrap dataset.'}
    $train=Invoke-BenchCompose $c @('--profile','jobs','run','-T','--rm','--no-deps','trainer','-mode','sequential','-config','data/configs/training.json') 'bootstrap/trainer' 180
    Assert-BenchSuccess $train 'Unmeasured isolated model preparation'
    $trained=ConvertFrom-BenchJsonData $train.stdout
    if($trained.run.status -ne 'completed' -or $trained.artifact.dataset_id -cne $loaded.manifest.dataset_id){throw 'Bootstrap model mismatch.'}
    $stop=Invoke-BenchCompose $c @('stop','worker') 'bootstrap/stop-idle-workers' 60
    Assert-BenchSuccess $stop 'Stop unused isolated workers'
    Write-BenchJson $record @{purpose='dataset/model preparation only; excluded from all measured repetitions';dataset_id=$loaded.manifest.dataset_id;snapshot_sha256=$loaded.manifest.snapshot.sha256;model_version=$trained.artifact.version;training_config=$trained.run.config;created_at=[datetime]::UtcNow.ToString('o')}
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
