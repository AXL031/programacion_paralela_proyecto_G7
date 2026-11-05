#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Prepare', 'Smoke', 'Run', 'Stop', 'Export')][string]$Action = 'Plan',
    [Parameter(Mandatory)][string]$Campaign,
    [string]$Config = 'configs/benchmark.json'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'benchmark/common.psm1') -Force -DisableNameChecking
$context = $null
$before = $null
$mutex = [Threading.Mutex]::new($false, 'TransporteG7BenchmarkHostV1')
$locked = $false
$exitCode = 0
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another benchmark operation holds the host lock. Wait for it to finish.' }
    if ($Campaign -cnotmatch '^[a-z0-9][a-z0-9-]{2,31}$') { throw 'Invalid campaign identifier.' }
    if ($Action -in @('Stop', 'Export')) {
        $context = Read-BenchJson ".cache/benchmark/$Campaign/context.json"
        Assert-BenchOwnership $context
    } else { $context = Initialize-BenchCampaign $Campaign $Config }
    if ($context.scope -eq 'real' -and $Action -in @('Prepare', 'Smoke', 'Run', 'Stop')) {
        $before = Get-BenchDemoState
        Write-BenchJson (Join-Path $context.results_dir "demo-before-$($Action.ToLowerInvariant()).json") $before
    }
    switch ($Action) {
        'Plan' {
            $plan = @(Read-BenchJson (Join-Path $context.results_dir 'plan.json'))
            $missing = @(Get-BenchMissingComponents $context.config)
            Write-Host ("Campaign {0}: scope={1}, {2} planned samples ({3} warmups)." -f $Campaign, $context.scope, $plan.Count, @($plan | Where-Object warmup).Count)
            if ($missing.Count) { Write-Host ('Pending adapters: ' + ($missing -join ', ')) }
        }
        'Prepare' { Prepare-BenchEnvironment $context }
        'Smoke' { Invoke-BenchSmoke $context }
        'Run' { Invoke-BenchCampaign $context }
        'Stop' {
            if ($context.scope -eq 'real') {
                $resolved = Assert-BenchCompose $context
                Assert-BenchExistingResources $context $resolved
                $down = Invoke-BenchCompose $context @('--profile', '*', 'down', '--remove-orphans', '--timeout', '15') 'stop' 90
                Assert-BenchSuccess $down 'Isolated shutdown'
            }
            Write-Host 'Campaign services stopped. Data, volumes, evidence and credentials retained.'
        }
        'Export' { Write-Host ('Evidence bundle: ' + (Export-BenchEvidence $context)) }
    }
} catch {
    $exitCode = 1
    $message = Protect-BenchText $_.Exception.Message
    if ($context) {
        Write-BenchJson (Join-Path $context.results_dir "error-$($Action.ToLowerInvariant()).json") @{ action = $Action; error = $message; at = [datetime]::UtcNow.ToString('o') }
    }
    [Console]::Error.WriteLine($message)
} finally {
    if ($null -ne $before -and $context) {
        try {
            $after = Get-BenchDemoState
            Write-BenchJson (Join-Path $context.results_dir "demo-after-$($Action.ToLowerInvariant()).json") $after
            $unchanged = ($before | ConvertTo-Json -Depth 30 -Compress) -ceq ($after | ConvertTo-Json -Depth 30 -Compress)
            Write-BenchJson (Join-Path $context.results_dir "preservation-$($Action.ToLowerInvariant()).json") @{ unchanged = $unchanged; mongo_observed = $before.mongo_status -eq 'observed'; file_count = $before.file_hashes.Count }
            if (-not $unchanged) { $exitCode = 1; [Console]::Error.WriteLine('Demo state changed during the operation; investigate before claiming preservation.') }
        } catch { $exitCode = 1; [Console]::Error.WriteLine('Could not verify demo preservation: ' + $_.Exception.Message) }
    }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit $exitCode
