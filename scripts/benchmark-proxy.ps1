#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Campaign)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'benchmark/common.psm1') -DisableNameChecking
$c=Read-BenchJson ".cache/benchmark/$Campaign/context.json"
Assert-BenchOwnership $c
$values=@{}
foreach($line in Get-Content -LiteralPath (Resolve-BenchPath '.env')){if($line -match '^([A-Z_]+)=(.*)$'){$values[$Matches[1]]=$Matches[2]}}
if(-not $values.DEMO_PASSWORD -or -not $values.DEMO_USER){throw 'Demo credentials are unavailable.'}
$environment=Read-BenchJson (Join-Path $c.results_dir 'environment.json')
# Compose images lists existing containers; --rm jobs no longer appear there.
# Prepare records the immutable ID of every built job image independently.
$imageID=[string]$environment.built_images['benchmark-api']
if($imageID -notmatch '^(sha256:)?[a-f0-9]{12,64}$'){throw 'Unexpected HTTP client image identity.'}
$directory=Join-Path $c.data_dir 'proxy'
[void][IO.Directory]::CreateDirectory($directory)
$previous=$env:BENCH_PASSWORD
try{
    $env:BENCH_PASSWORD=$values.DEMO_PASSWORD
    $call=Invoke-BenchProcess 'docker' @('run','--rm','--network','transporte-g7_default','--cpus','2','--memory','256m','--env','BENCH_PASSWORD','--volume',"$($c.data_dir):/app/data",$imageID,'-base-url','http://web:3000','-user',[string]$values.DEMO_USER,'-cache','warm','-concurrency','10','-requests','1000','-output','data/proxy/report.json') 120 (Join-Path $c.raw_dir 'logs/proxy-client')
    Assert-BenchSuccess $call 'Separate read-only prediction pass through demo proxy'
    $report=Read-BenchJson (Join-Path $directory 'report.json')
    $report.route='demo web proxy, separate from isolated direct REST campaign'
    Write-BenchJson (Join-Path $c.results_dir 'proxy-report.json') $report
}finally{
    if($null -eq $previous){Remove-Item Env:BENCH_PASSWORD -ErrorAction SilentlyContinue}else{$env:BENCH_PASSWORD=$previous}
}
