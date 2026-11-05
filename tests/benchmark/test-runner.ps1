#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/benchmark/common.psm1') -Force -DisableNameChecking
$root = Get-BenchRoot
$pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$runner = Join-Path $root 'scripts/benchmark.ps1'
$prefix = 'test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$checks = [Collections.Generic.List[string]]::new()
function Assert-Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAILED: $Name" }
    $checks.Add($Name)
}
function Assert-Rejected([scriptblock]$Operation, [string]$Name) {
    $rejected = $false
    try { & $Operation } catch { $rejected = $true }
    Assert-Check $rejected $Name
}
function Invoke-Fixture([string]$Suffix, [string]$Behavior = 'normal') {
    $config = Read-BenchJson 'tests/benchmark/fixtures/config.json'
    $config.fixture_behavior = $Behavior
    $configPath = ".cache/benchmark-tests/$prefix-$Suffix.json"
    Write-BenchJson $configPath $config
    $campaign = "$prefix-$Suffix"
    $call = Invoke-BenchProcess $pwsh @('-NoProfile', '-File', $runner, '-Action', 'Run', '-Campaign', $campaign, '-Config', $configPath) 90
    return @{ call = $call; manifest = (Read-BenchJson "bench/results/$campaign/manifest.json"); campaign = $campaign; config = $configPath }
}

$real = Get-BenchConfiguration 'configs/benchmark.json'
$plan = @(New-BenchPlan $real 'test-plan')
Assert-Check ($plan.Count -eq 63) 'real plan has 63 samples'
Assert-Check (@($plan | Where-Object warmup).Count -eq 6) 'six excluded warmups'
Assert-Check (@($plan | Where-Object kind -EQ 'api').Count -eq 27) '27 API passes'
Assert-Check (@($plan.sample_id | Select-Object -Unique).Count -eq 63) 'unique sample identifiers'
Assert-Check ((New-BenchPlan $real 'test-plan' | ConvertTo-Json -Depth 10 -Compress) -ceq ($plan | ConvertTo-Json -Depth 10 -Compress)) 'deterministic plan order'
Assert-Rejected { Resolve-BenchPath '../outside' } 'path traversal rejected'
Assert-Rejected { Resolve-BenchPath ($root + '-sibling/file') } 'sibling prefix rejected'
$invalid = Read-BenchJson 'tests/benchmark/fixtures/config.json'
$invalid.scope = 'real'
Write-BenchJson ".cache/benchmark-tests/$prefix-invalid.json" $invalid
Assert-Rejected { Get-BenchConfiguration ".cache/benchmark-tests/$prefix-invalid.json" } 'synthetic adapter cannot masquerade as real'

$success = Invoke-Fixture 'success'
Assert-Check ($success.call.exit_code -eq 0) ('offline fixture run succeeds: ' + $success.call.stderr)
Assert-Check ($success.manifest.state -eq 'fixture_passed' -and -not $success.manifest.objective_evaluated) 'synthetic success never claims real objectives'
Assert-Check (@($success.manifest.samples).Count -eq 7 -and @($success.manifest.samples | Where-Object state -NE 'passed').Count -eq 0) 'all seven fixture samples dispatched'
$fixtureContext = Read-BenchJson ".cache/benchmark/$($success.campaign)/context.json"
$fixturePlan = @(Read-BenchJson "bench/results/$($success.campaign)/plan.json")
$loadPlan = $fixturePlan | Where-Object kind -EQ 'load' | Select-Object -First 1
$loadResult = Read-BenchJson "bench/results/$($success.campaign)/samples/$($loadPlan.sample_id).json"
$validationPath = Join-Path $fixtureContext.results_dir 'validation-only.json'
$loadResult.metrics.accepted = '3'
Write-BenchJson $validationPath $loadResult
Assert-Rejected { Assert-BenchSample $fixtureContext $loadPlan $validationPath } 'schema rejects text instead of numeric metric'
$loadResult.metrics.accepted = 3
$loadResult.timings.total_seconds = -1
Write-BenchJson $validationPath $loadResult
Assert-Rejected { Assert-BenchSample $fixtureContext $loadPlan $validationPath } 'schema rejects negative timing'
$trainingPlan = $fixturePlan | Where-Object case_id -EQ 'D1' | Select-Object -First 1
$trainingResult = Read-BenchJson "bench/results/$($success.campaign)/samples/$($trainingPlan.sample_id).json"
$trainingResult.metrics.workers = @()
Write-BenchJson $validationPath $trainingResult
Assert-Rejected { Assert-BenchSample $fixtureContext $trainingPlan $validationPath } 'missing worker contributions rejected'
$trainingResult = Read-BenchJson "bench/results/$($success.campaign)/samples/$($trainingPlan.sample_id).json"
$realContext = $fixtureContext | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
$realContext.scope = 'real'
$realContext.config.inputs.training='configs/training.json'
$trainingResult.scope = 'real'
$resourcePath = Join-Path $fixtureContext.raw_dir 'validation-resources.ndjson'
$resource = @{schema_version='benchmark-v1';sample_id=$trainingPlan.sample_id;sampled_at=[datetime]::UtcNow.ToString('o');service='worker';scope='process';available=$true;cpu_percent=50;memory_bytes=1024}
Write-BenchJson $resourcePath $resource
# NDJSON contains one compact JSON observation per line.
[IO.File]::WriteAllText($resourcePath, ($resource | ConvertTo-Json -Compress) + "`n")
$trainingResult.resources = @{status='available';path=[IO.Path]::GetRelativePath($root,$resourcePath).Replace('\','/');sha256=(Get-FileHash -LiteralPath $resourcePath).Hash.ToLowerInvariant();valid_samples=1;missing_samples=0}
$diagnosticsPath = Join-Path $fixtureContext.raw_dir 'validation-candidate.json'
$trainingConfig=Read-BenchJson 'configs/training.json'
$trainingConfig.workers=1
$diagnostics = @{schema_version='candidate-diagnostics-v1';sample_id=$trainingPlan.sample_id;mode='distributed';run_id='distributed-test';reference_run_id='reference-test';reference_mode='sequential';dataset_id=$trainingResult.dataset.id;snapshot_sha256=$trainingResult.dataset.snapshot_sha256;encoder_sha256=('e'*64);encoder_version='test';seed=42;config=$trainingConfig;train_examples=1;validation_examples=1;test_examples=1;dimension=2;total_steps=1;absolute_tolerance=1e-9;relative_tolerance=1e-9;equivalent=$true;reference_weights=@(1.0,2.0);candidate_weights=@(1.0,2.0)}
$referencePath=Join-Path $fixtureContext.raw_dir 'reference/sequential-diagnostics.json'
$reference=ConvertFrom-BenchJsonData ($diagnostics | ConvertTo-Json -Depth 20)
$reference.mode='sequential';$reference.run_id='reference-test';$reference.reference_run_id='reference-test';$reference.sample_id='reference-S'
Write-BenchJson $referencePath $reference
$modelPath=Join-Path $fixtureContext.raw_dir 'reference/published-model.json'
Write-BenchJson $modelPath @{dataset_id=$trainingResult.dataset.id;snapshot_sha256=$trainingResult.dataset.snapshot_sha256;weights=@(0.0,0.0)}
$trainingResult.metrics.reference_model_path=[IO.Path]::GetRelativePath($root,$modelPath).Replace('\','/')
$trainingResult.metrics.reference_model_sha256=(Get-FileHash $modelPath).Hash.ToLowerInvariant()
$trainingResult.metrics.published_weights=@(0.0,0.0)
$trainingResult.metrics.run_id='distributed-test'
$trainingResult.metrics.reference_diagnostics_path=[IO.Path]::GetRelativePath($root,$referencePath).Replace('\','/')
$trainingResult.metrics.reference_diagnostics_sha256=(Get-FileHash -LiteralPath $referencePath).Hash.ToLowerInvariant()
Write-BenchJson $diagnosticsPath $diagnostics
$trainingResult.metrics.candidate_diagnostics_path = [IO.Path]::GetRelativePath($root,$diagnosticsPath).Replace('\','/')
$trainingResult.metrics.candidate_diagnostics_sha256 = (Get-FileHash -LiteralPath $diagnosticsPath).Hash.ToLowerInvariant()
Write-BenchJson $validationPath $trainingResult
[void](Assert-BenchSample $realContext $trainingPlan $validationPath)
Assert-Check $true 'real resource lines and pre-selection candidate evidence accepted'
foreach($bad in @('self-reference','wrong-dataset','wrong-encoder','wrong-config')){
    $original=ConvertFrom-BenchJsonData ($diagnostics | ConvertTo-Json -Depth 20)
    switch($bad){
        'self-reference' {$diagnostics.reference_run_id=$diagnostics.run_id;$diagnostics.reference_mode='distributed'}
        'wrong-dataset' {$diagnostics.dataset_id='unrelated'}
        'wrong-encoder' {$diagnostics.encoder_sha256='f'*64}
        'wrong-config' {$diagnostics.config.epochs=1}
    }
    Write-BenchJson $diagnosticsPath $diagnostics
    $trainingResult.metrics.candidate_diagnostics_sha256=(Get-FileHash $diagnosticsPath).Hash.ToLowerInvariant()
    Write-BenchJson $validationPath $trainingResult
    Assert-Rejected { Assert-BenchSample $realContext $trainingPlan $validationPath } $bad
    $diagnostics=$original
}
Write-BenchJson $diagnosticsPath $diagnostics
$diagnostics.candidate_weights[1] = 3.0
Write-BenchJson $diagnosticsPath $diagnostics
$trainingResult.metrics.candidate_diagnostics_sha256 = (Get-FileHash -LiteralPath $diagnosticsPath).Hash.ToLowerInvariant()
Write-BenchJson $validationPath $trainingResult
Assert-Rejected { Assert-BenchSample $realContext $trainingPlan $validationPath } 'different candidate cannot be hidden by equivalent published models'
$trainingResult.resources.sha256 = 'f' * 64
Write-BenchJson $validationPath $trainingResult
Assert-Rejected { Assert-BenchSample $realContext $trainingPlan $validationPath } 'resource checksum tampering rejected'
$retry = Invoke-BenchProcess $pwsh @('-NoProfile', '-File', $runner, '-Action', 'Run', '-Campaign', $success.campaign, '-Config', $success.config) 30
Assert-Check ($retry.exit_code -ne 0) 'existing run cannot be overwritten'
foreach ($behavior in @('exit', 'no-output', 'mismatch', 'real-scope', 'reused', 'bad-check', 'bad-cache', 'partial-summary')) {
    $failure = Invoke-Fixture $behavior $behavior
    Assert-Check ($failure.call.exit_code -ne 0 -and $failure.manifest.state -eq 'failed') "failure preserved: $behavior"
    Assert-Check (@($failure.manifest.errors).Count -gt 0) "cause recorded: $behavior"
}
$context = Initialize-BenchCampaign "$prefix-missing" 'configs/benchmark.json'
Assert-Rejected { Invoke-BenchCampaign $context } 'unprepared campaign rejected before Docker execution'
$blocked = Read-BenchJson (Join-Path $context.results_dir 'manifest.json')
$missing=@(Get-BenchMissingComponents $context.config)
Assert-Check (($missing.Count -eq 0 -and $blocked.state -eq 'planned') -or ($missing.Count -gt 0 -and $blocked.state -eq 'blocked')) 'integration/preparation state explicit'
$context.project = 'transporte-g7'
Assert-Rejected { Assert-BenchOwnership $context } 'demo project cannot be adopted'
$context.project = "transporte-g7-bench-$($context.campaign_id)"
$context.data_dir = Resolve-BenchPath 'data'
Assert-Rejected { Assert-BenchOwnership $context } 'demo data directory cannot be adopted'

$sleepPath = ".cache/benchmark-tests/$prefix-sleep.ps1"
[IO.File]::WriteAllText((Resolve-BenchPath $sleepPath), 'Start-Sleep -Seconds 10')
$timeout = Invoke-BenchProcess $pwsh @('-NoProfile', '-File', (Resolve-BenchPath $sleepPath)) 1
Assert-Check ($timeout.exit_code -eq 124 -and $timeout.stderr.Contains('timeout')) 'timeout kills child and preserves cause'
$mutex = [Threading.Mutex]::new($false, 'TransporteG7BenchmarkHostV1')
try {
    [void]$mutex.WaitOne(0)
    $overlap = Invoke-BenchProcess $pwsh @('-NoProfile', '-File', $runner, '-Action', 'Plan', '-Campaign', "$prefix-locked") 20
    Assert-Check ($overlap.exit_code -ne 0 -and $overlap.stderr.Contains('host lock')) 'overlapping processes rejected'
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
Write-Output ("PASS: {0} checks. All generated data is synthetic; no Docker/real benchmarks were run." -f $checks.Count)
Write-BenchJson '.cache/benchmark-tests/latest.json' @{status='passed';checks=@($checks.ToArray());check_count=$checks.Count;scope='orchestrator_fixture';at=[datetime]::UtcNow.ToString('o')}
