#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContextPath,
    [Parameter(Mandatory)][string]$SamplePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$StopFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'benchmark/common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'benchmark/resources.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'benchmark/statistics.psm1') -Force -DisableNameChecking
$context = Read-BenchJson $ContextPath
Assert-BenchOwnership $context
if ($context.scope -ne 'real') { throw 'Resource collector requires an isolated real context; use unit fixtures for offline checks.' }
$sample = Read-BenchJson $SamplePath
$plan = @(Read-BenchJson (Join-Path $context.results_dir 'plan.json'))
$match = @($plan | Where-Object sample_id -CEQ $sample.sample_id)
if ($match.Count -ne 1 -or (ConvertTo-BenchCanonicalJson $match[0]) -cne (ConvertTo-BenchCanonicalJson $sample)) { throw 'Unknown or modified sample plan.' }
$output = Resolve-BenchPath (Resolve-BenchPath $OutputPath) $context.raw_dir
$stop = Resolve-BenchPath (Resolve-BenchPath $StopFile) $context.raw_dir
$coveragePath = $output + '.coverage.json'
if ($output -eq $stop -or $coveragePath -eq $stop -or (Test-Path -LiteralPath $stop) -or (Test-Path -LiteralPath $coveragePath)) { throw 'Collector paths collide or already exist.' }
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stop))
$stream = [IO.File]::Open($output, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
$previous = @{}; $known = @{}
$valid = 0; $missing = 0; $cycles = 0
$validProcesses = @{}
$errors = [Collections.Generic.List[string]]::new()
$intervals = [Collections.Generic.List[double]]::new()
$started = [datetimeoffset]::UtcNow
$clock = [Diagnostics.Stopwatch]::StartNew()
$lastCycle = $null
$fatal = $false
try {
    while (-not (Test-Path -LiteralPath $stop)) {
        if ($clock.Elapsed.TotalSeconds -ge $context.config.timeout_seconds) { throw 'Collector exceeded campaign timeout without a stop signal.' }
        $cycle = $clock.Elapsed.TotalSeconds
        if ($null -ne $lastCycle) { $intervals.Add($cycle - $lastCycle) }
        $lastCycle = $cycle; $cycles++
        $snapshot = Get-BenchResourceSnapshot $context $sample.sample_id $previous $known {
            param([string[]]$Arguments)
            Invoke-BenchProcess 'docker' $Arguments 10
        }
        foreach ($row in $snapshot.observations) {
            $writer.WriteLine(($row | ConvertTo-Json -Compress))
            if ($row.available) {
                $valid++
                if ($row.scope -eq 'process') { $validProcesses[$row.service] = $true }
            } else { $missing++ }
        }
        foreach ($message in $snapshot.errors) { $errors.Add($message) }
        # This is a target cadence, not a claim of 1 Hz. Actual intervals are saved.
        while ($clock.Elapsed.TotalSeconds - $cycle -lt 1 -and -not (Test-Path -LiteralPath $stop)) { Start-Sleep -Milliseconds 100 }
    }
    if ($valid -eq 0) { throw 'Collector captured no valid resource observations.' }
    $required = switch ($sample.kind) {
        'load' { @{ loader = 1 } }
        'training' { if ($sample.parameters.mode -eq 'sequential') { @{ trainer = 1 } } else { @{ master = 1; worker = $sample.parameters.workers } } }
        'api' { @{ api = 1 } }
    }
    foreach ($role in $required.Keys) {
        if (@($validProcesses.Keys | Where-Object { $_.StartsWith($role + '/', [StringComparison]::Ordinal) }).Count -ne $required[$role]) {
            throw "Missing process coverage or unexpected process count for $role; cannot certify this sample."
        }
    }
} catch {
    $fatal = $true
    $errors.Add($_.Exception.Message)
} finally {
    $writer.Dispose(); $clock.Stop()
    Write-BenchJson $coveragePath @{
        schema_version = 'benchmark-v1'; sample_id = $sample.sample_id; campaign_id = $context.campaign_id
        started_at = $started.ToString('o'); completed_at = [datetimeoffset]::UtcNow.ToString('o')
        status = $(if ($fatal) { 'failed' } else { 'captured' }); cycles = $cycles; requested_interval_seconds = 1
        actual_intervals_seconds = @($intervals.ToArray()); valid_samples = $valid; missing_samples = $missing
        services = @($known.Values | ForEach-Object service); valid_process_services = @($validProcesses.Keys)
        errors = @($errors.ToArray()); sha256 = (Get-FileHash -LiteralPath $output).Hash.ToLowerInvariant()
        limitations = @('Docker stats is batched; process reads are sequential and may exceed 1 s. Inspect actual intervals.', 'Container timestamps identify receipt of a stats batch, not simultaneous kernel reads.', 'Process CPU needs two observations; initial/reset counters are unavailable.', 'Container memory follows Docker CLI semantics and displayed precision; process memory is RSS.', 'Jobs shorter than discovery/collection can be missed; required process coverage must pass and temporal coverage still needs review.')
    }
}
if ($fatal) { throw 'Resource collection failed; inspect the preserved coverage report.' }
