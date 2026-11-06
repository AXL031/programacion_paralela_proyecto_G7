#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/benchmark/common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../scripts/benchmark/statistics.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../scripts/benchmark/resources.psm1') -Force -DisableNameChecking
$checks = [Collections.Generic.List[string]]::new()
function Assert-Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAILED: $Name" }
    $checks.Add($Name)
}
function Assert-Rejected([scriptblock]$Operation, [string]$Name) {
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Assert-Check $rejected $Name
}
$stats = Get-BenchStatistics @(2, 4, 4, 4, 5, 5, 7, 9)
Assert-Check ($stats.mean -eq 5 -and $stats.median -eq 4.5 -and [Math]::Abs($stats.sample_stddev - [Math]::Sqrt(32 / 7)) -lt 1e-12) 'known mean, even median and sample deviation'
Assert-Check ((Get-BenchStatistics @(9, 1, 3)).median -eq 3 -and $null -eq (Get-BenchStatistics @(1)).sample_stddev) 'odd median and undefined single-sample deviation'
Assert-Check ((Get-BenchStatistics @(0, 0)).mean -eq 0) 'zero is a valid observation'
Assert-Check ((ConvertTo-BenchCanonicalJson ([ordered]@{ a = @(1, 2); b = $null })) -ceq (ConvertTo-BenchCanonicalJson ([ordered]@{ b = $null; a = @(1, 2) }))) 'JSON property order does not affect compatibility'
foreach ($bad in @(@(), @($null), @('1'), @($true), @(-1), @([double]::NaN), @([double]::PositiveInfinity))) {
    Assert-Rejected { Get-BenchStatistics $bad } 'empty/invalid statistics rejected'
}
Assert-Rejected { Get-BenchSpeedup 1 1 0 2 } 'zero denominator rejected'
Assert-Rejected { Get-BenchSpeedup 1 1 1 3 } 'unsupported worker count rejected'
$ratios = Get-BenchSpeedup 10 12 20 4
Assert-Check ($ratios.speedup_vs_sequential -eq 0.5 -and $ratios.speedup_vs_d1 -eq 0.6 -and $ratios.efficiency_vs_d1 -eq 0.15) 'slowdown is retained without clamping'
Assert-Check ((ConvertFrom-BenchMemory '1.5MiB') -eq 1572864 -and (ConvertFrom-BenchMemory '1.5MB') -eq 1500000) 'binary/decimal Docker units distinguished'
Assert-Rejected { ConvertFrom-BenchMemory 'not available' } 'missing Docker memory is not zero'
$fields = @('S') + @(1..49 | ForEach-Object { '0' })
$fields[11] = '100'; $fields[12] = '50'; $fields[19] = '123'
$proc = "100`n1 (service name) $($fields -join ' ')`nVmRSS: 2048 kB`n"
$at = [datetimeoffset]::Parse('2026-11-05T12:00:00Z')
$first = Get-BenchProcessObservation $proc $null $at 'S-r1' 'trainer/test'
$second = Get-BenchProcessObservation ($proc.Replace('100 50', '150 50')) $first.counters $at.AddSeconds(1) 'S-r1' 'trainer/test'
Assert-Check (-not $first.observation.available -and $second.observation.cpu_percent -eq 50 -and $second.observation.memory_bytes -eq 2097152) 'process CPU delta and RSS; initial observation missing'
$reset = Get-BenchProcessObservation ($proc.Replace('123', '124')) $first.counters $at.AddSeconds(1) 'S-r1' 'trainer/test'
Assert-Check (-not $reset.observation.available) 'restarted process resets CPU baseline'
Assert-Rejected { ConvertFrom-BenchProc 'truncated' } 'invalid proc evidence rejected'
$observations = @(
    (New-BenchObservation 'D2-r1' 'worker-a' 'process' $at 10 100),
    (New-BenchObservation 'D2-r1' 'worker-b' 'process' $at 20 20),
    (New-BenchObservation 'D2-r1' 'worker-a' 'process' $at.AddSeconds(1) 30 30),
    (New-BenchObservation 'D2-r1' 'worker-b' 'process' $at.AddSeconds(1) 40 200),
    (New-BenchObservation 'D2-r1' 'worker-a' 'process' $at.AddSeconds(2)),
    (New-BenchObservation 'D2-r1' 'worker-b' 'process' $at.AddSeconds(2) 40 200),
    (New-BenchObservation 'D2-r1' 'worker-a' 'container' $at 1 999)
)
$summary = Get-BenchResourceSummary $observations
$total = $summary.totals | Where-Object scope -EQ 'process'
Assert-Check ($total.max_memory_bytes -eq 230 -and $total.aligned_samples -eq 2 -and $total.cpu_percent.mean -eq 50) 'aligned RAM sums, missing observations excluded, scopes separated'
$desynchronized = @($observations[0], (New-BenchObservation 'D2-r1' 'worker-b' 'process' $at.AddSeconds(3) 20 200))
Assert-Check ($null -eq (Get-BenchResourceSummary $desynchronized).totals[0].max_memory_bytes) 'unaligned observations never form a fabricated total'
Assert-Check ($null -eq (Get-BenchResourceSummary @()).totals[0].max_memory_bytes) 'empty resource evidence stays unavailable'
foreach ($row in $observations) {
    Assert-Check (Test-Json -Json ($row | ConvertTo-Json -Compress) -SchemaFile (Resolve-BenchPath 'schemas/benchmark-resource.schema.json')) 'resource record conforms to shared schema'
}
# Exercise collection without invoking Docker, allocating containers or downloading images.
$id = 'a' * 64
$context = @{ campaign_id = 'test-resources'; project = 'transporte-g7-bench-test-resources' }
$fake = { param([string[]]$Arguments)
    $stdout = switch ($Arguments[0]) {
        'ps' { $id }
        'inspect' { @{ labels = @{ 'com.docker.compose.project' = $context.project; 'g7.benchmark.managed' = 'benchmark-v1'; 'g7.benchmark.campaign' = $context.campaign_id; 'com.docker.compose.service' = 'trainer' }; running = $true } | ConvertTo-Json -Compress }
        'stats' { @{ ID = $id; CPUPerc = '25.00%'; MemUsage = '2MiB / 1GiB' } | ConvertTo-Json -Compress }
        'exec' { $proc }
        default { throw 'Unexpected Docker command in fixture.' }
    }
    return @{ exit_code = 0; stdout = $stdout; stderr = '' }
}.GetNewClosure()
$previous = @{}; $known = @{}
$stopped = { param([string[]]$Arguments)
    if($Arguments[0] -eq 'ps'){return @{exit_code=0;stdout=$id;stderr=''}}
    return @{exit_code=0;stdout=(@{labels=@{'com.docker.compose.project'=$context.project;'g7.benchmark.managed'='benchmark-v1';'g7.benchmark.campaign'=$context.campaign_id;'com.docker.compose.service'='worker'};running=$false}|ConvertTo-Json -Compress);stderr=''}
}.GetNewClosure()
$inactiveKnown=@{}
$inactive=Get-BenchResourceSnapshot $context 'S-r1' @{} $inactiveKnown $stopped
Assert-Check ($inactiveKnown.Count -eq 0 -and $inactive.observations.Count -eq 0) 'workers stopped before collection do not invalidate active-resource totals'
$snapshot = Get-BenchResourceSnapshot $context 'S-r1' $previous $known $fake
Assert-Check ($snapshot.observations.Count -eq 2 -and $snapshot.observations[0].memory_bytes -eq 2097152 -and -not $snapshot.observations[1].available) 'collector discovery and first baseline with fake Docker'
$absent = { param([string[]]$Arguments) return @{ exit_code = 0; stdout = ''; stderr = '' } }
$snapshot = Get-BenchResourceSnapshot $context 'S-r1' $previous $known $absent
Assert-Check ($snapshot.observations.Count -eq 2 -and @($snapshot.observations | Where-Object available).Count -eq 0) 'removed transient job produces missing observations'
$foreign = { param([string[]]$Arguments)
    if ($Arguments[0] -eq 'ps') { return @{ exit_code = 0; stdout = ('a' * 64) } }
    return @{ exit_code = 0; stdout = '{"labels":{"com.docker.compose.project":"transporte-g7"},"running":true}' }
}
Assert-Rejected { Get-BenchResourceSnapshot $context 'S-r1' @{} @{} $foreign } 'collector rejects demo/foreign containers'
$broken = { param([string[]]$Arguments)
    if ($Arguments[0] -in @('stats', 'exec')) { return @{ exit_code = 1; stdout = ''; stderr = 'fixture failure' } }
    return & $fake $Arguments
}.GetNewClosure()
$snapshot = Get-BenchResourceSnapshot $context 'S-r1' @{} @{} $broken
Assert-Check ($snapshot.observations.Count -eq 2 -and @($snapshot.observations | Where-Object available).Count -eq 0 -and $snapshot.errors.Count -ge 2) 'failed stats/proc reads remain missing and retain causes'

# Full agreed case matrix with deliberately synthetic values; exercise the actual
# summary adapter, including its public ContextPath/ManifestPath/OutputPath interface.
$campaign = 'test-gerardo-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$config = Read-BenchJson 'tests/benchmark/fixtures/config.json'
$config.protocol = (Read-BenchJson 'configs/benchmark.json').protocol
$configPath = ".cache/benchmark-tests/$campaign.json"
Write-BenchJson $configPath $config
$context = Initialize-BenchCampaign $campaign $configPath
$manifestPath = Join-Path $context.results_dir 'manifest.json'
$manifest = Read-BenchJson $manifestPath
$plan = @(Read-BenchJson (Join-Path $context.results_dir 'plan.json'))
foreach ($item in $plan) {
    $inputPath = Join-Path $context.raw_dir "$($item.sample_id).json"
    $outputPath = Join-Path $context.results_dir "samples/$($item.sample_id).json"
    Write-BenchJson $inputPath $item
    & (Resolve-BenchPath 'tests/benchmark/fixtures/adapter.ps1') -ContextPath $context.context_path -SamplePath $inputPath -OutputPath $outputPath | Out-Null
    $result = Read-BenchJson $outputPath
    $time = if ($item.warmup) { 1000 } elseif ($item.kind -eq 'training') { @{ S = 10; D1 = 12; D2 = 8; D4 = 20 }[$item.case_id] } else { 1 }
    $result.timings.compute_seconds = $time
    $result.timings.total_seconds = $time * 2
    Write-BenchJson $outputPath $result
    $manifest.samples += @{ sample_id = $item.sample_id; state = 'passed'; warmup = $item.warmup; result = [IO.Path]::GetRelativePath((Get-BenchRoot), $outputPath).Replace('\', '/') }
}
Write-BenchJson $manifestPath $manifest
$summaryPath = Join-Path $context.results_dir 'summary.json'
$adapter = Resolve-BenchPath 'scripts/benchmark-summary.ps1'
function Invoke-Summary { & $adapter -ContextPath $context.context_path -ManifestPath $manifestPath -OutputPath $summaryPath }
Invoke-Summary
$report = Read-BenchJson $summaryPath
$s = $report.timings | Where-Object { $_.case_id -eq 'S' -and $_.phase -eq 'compute_seconds' }
$d4 = $report.speedups | Where-Object { $_.case_id -eq 'D4' -and $_.phase -eq 'compute_seconds' }
Assert-Check ($report.sample_ids.Count -eq 63 -and $report.excluded_warmup_ids.Count -eq 6 -and $s.statistics.count -eq 5 -and $s.statistics.median -eq 10) 'complete matrix aggregated with warmups excluded'
Assert-Check ($d4.ratios.speedup_vs_sequential -eq 0.5 -and $d4.ratios.efficiency_vs_d1 -eq 0.15) 'summary preserves unfavorable results'
Assert-Check ($report.scope -eq 'orchestrator_fixture' -and $report.resources.Count -eq 0 -and $report.limitations[-1] -match 'SYNTHETIC') 'fixture never claims real results'
Assert-Check ((Import-Csv -LiteralPath (Join-Path $context.results_dir 'summary-speedups.csv')).Count -eq 6) 'CSV contains both core and total comparisons'
$record = $manifest.samples[0]
$record.state = 'failed'; Write-BenchJson $manifestPath $manifest
Assert-Rejected { Invoke-Summary } 'failed manifest rejected'
$record.state = 'passed'; $manifest.samples += $record; Write-BenchJson $manifestPath $manifest
Assert-Rejected { Invoke-Summary } 'duplicate sample rejected'
$manifest.samples = @($manifest.samples | Select-Object -SkipLast 1); Write-BenchJson $manifestPath $manifest
$last = $manifest.samples[-1]
$manifest.samples = @($manifest.samples | Select-Object -SkipLast 1); Write-BenchJson $manifestPath $manifest
Assert-Rejected { Invoke-Summary } 'incomplete campaign rejected'
$manifest.samples += $last; Write-BenchJson $manifestPath $manifest
$file = Resolve-BenchPath $manifest.samples[-1].result
$original = Read-BenchJson $file
$different = Read-BenchJson $file; $different.dataset.snapshot_sha256 = 'f' * 64; Write-BenchJson $file $different
Assert-Rejected { Invoke-Summary } 'incompatible snapshots rejected'
Write-BenchJson $file $original
$trainingRecord = $manifest.samples | Where-Object sample_id -EQ 'D2-r1'
$trainingFile = Resolve-BenchPath $trainingRecord.result
$original = Read-BenchJson $trainingFile
$invalid = Read-BenchJson $trainingFile; $invalid.timings.compute_seconds = 0; Write-BenchJson $trainingFile $invalid
Assert-Rejected { Invoke-Summary } 'zero core time rejected'
Write-BenchJson $trainingFile $original
$invalid = Read-BenchJson $trainingFile; $invalid.metrics.workers = @('one'); Write-BenchJson $trainingFile $invalid
Assert-Rejected { Invoke-Summary } 'missing worker contribution rejected before aggregation'
Write-BenchJson $trainingFile $original
$plan[0].parameters.workers = 99; Write-BenchJson (Join-Path $context.results_dir 'plan.json') $plan
Assert-Rejected { Invoke-Summary } 'modified case/configuration plan rejected'
Write-BenchJson (Join-Path $context.results_dir 'plan.json') @(New-BenchPlan $config $campaign)
$pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$child = Invoke-BenchProcess $pwsh @('-NoProfile', '-File', $adapter, '-ContextPath', $context.context_path, '-ManifestPath', $manifestPath, '-OutputPath', $summaryPath) 90
Assert-Check ($child.exit_code -eq 0) ('summary works in a separate runner child process: ' + $child.stderr)
Write-BenchJson '.cache/benchmark-tests/gerardo-latest.json' @{ status = 'passed'; scope = 'orchestrator_fixture'; check_count = $checks.Count; checks = @($checks.ToArray()); campaign = $campaign; at = [datetimeoffset]::UtcNow.ToString('o') }
Write-Output ("PASS: {0} checks. Synthetic fixtures only; no Docker/real benchmark executed." -f $checks.Count)
