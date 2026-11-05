#Requires -Version 7.2
# Load adapter for benchmark-v1 (issue #2).
#
# The runner invokes this script once per planned load sample with the exact
# ContextPath/SamplePath/OutputPath interface from docs/CONTRATO_BENCHMARK.md.
# A real sample uses a fresh g7_benchmark database inside the isolated project:
# validate ownership and Compose resources, refuse to run while a loader or
# trainer is active, drop only the fixed benchmark database, prove it is empty,
# run the existing loader with -require-fresh, then verify the snapshot and the
# persisted MongoDB data independently.
#
# Phase semantics are the loader's own instrumentation:
#   preparation = config/checksum/zone/period preparation and store.Begin
#   compute     = ingestion/validation/inserts plus the post-ingestion re-hash
#   evaluation  = null (no evaluation phase for load)
#   publication = snapshot/window export plus store.Complete
#   total       = loader start through store.Complete
# Adapter overhead (preflight, database reset, resource collector, verification)
# is deliberately excluded from those phases.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContextPath,
    [Parameter(Mandatory)][string]$SamplePath,
    [Parameter(Mandatory)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'benchmark/common.psm1') -Force -DisableNameChecking

function Get-BenchRequired($Map, [string]$Key, [string]$What) {
    if ($null -eq $Map -or -not ($Map -is [System.Collections.IDictionary]) -or -not $Map.Contains($Key)) {
        throw "$What is missing $Key."
    }
    return $Map[$Key]
}

function Get-BenchValue($Map, [string]$Key, $Default = $null) {
    if ($null -eq $Map -or -not ($Map -is [System.Collections.IDictionary]) -or -not $Map.Contains($Key)) {
        return $Default
    }
    return $Map[$Key]
}

function ConvertFrom-BenchJsonText([string]$Text, [string]$What) {
    if ([string]::IsNullOrWhiteSpace($Text)) { throw "$What produced no JSON output." }
    $trimmed = $Text.Trim()
    try {
        $parsed = ConvertFrom-BenchJsonData $trimmed
        if ($parsed -is [System.Collections.IDictionary]) { return $parsed }
    } catch { }
    $lines = @($trimmed -split '\r?\n')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '{') {
            $candidate = ($lines[$i..($lines.Count - 1)] -join "`n")
            try {
                $parsed = ConvertFrom-BenchJsonData $candidate
                if ($parsed -is [System.Collections.IDictionary]) { return $parsed }
            } catch { }
        }
    }
    $first = $trimmed.IndexOf('{')
    $last = $trimmed.LastIndexOf('}')
    if ($first -ge 0 -and $last -gt $first) {
        $candidate = $trimmed.Substring($first, $last - $first + 1)
        try {
            $parsed = ConvertFrom-BenchJsonData $candidate
            if ($parsed -is [System.Collections.IDictionary]) { return $parsed }
        } catch { }
    }
    throw "$What output is not a valid JSON object."
}

function Get-BenchJsonLine([string]$Text, [string]$What) {
    if ([string]::IsNullOrWhiteSpace($Text)) { throw "$What returned no JSON." }
    $lines = @($Text -split '\r?\n' | Where-Object { $_.Trim() })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try {
            $parsed = ConvertFrom-BenchJsonData $lines[$i]
            if ($parsed -is [System.Collections.IDictionary]) { return $parsed }
        } catch { }
    }
    throw "$What did not return a JSON object."
}

function Add-BenchCheck($Checks, $Errors, [string]$Name, [bool]$Condition, [string]$Message) {
    $Checks[$Name] = $Condition
    if (-not $Condition) { $Errors.Add("${Name}: $Message") }
}

function Test-BenchHash([string]$Value) {
    return ($Value -match '^[a-f0-9]{64}$')
}

function Test-BenchId([string]$Value, [string]$Pattern = '^[A-Za-z0-9_-]{1,128}$') {
    return ($Value -match $Pattern)
}

function Test-BenchInteger($Value) {
    if ($null -eq $Value -or $Value -is [string]) { return $false }
    return ($Value -is [int] -or $Value -is [long])
}

function Test-BenchNumber($Value) {
    if ($null -eq $Value -or $Value -is [string]) { return $false }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) { return $false }
    return [double]::IsFinite([double]$Value)
}

function Test-BenchClose([double]$Actual, [double]$Expected, [double]$Tolerance = 1e-9) {
    if (-not [double]::IsFinite($Actual) -or -not [double]::IsFinite($Expected)) { return $false }
    $scale = [Math]::Max(1.0, [Math]::Max([Math]::Abs($Actual), [Math]::Abs($Expected)))
    return ([Math]::Abs($Actual - $Expected) -le $Tolerance * $scale)
}

function ConvertTo-BenchUtc([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return [datetimeoffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-BenchCanonicalMap($Map) {
    $ordered = [ordered]@{}
    if ($null -eq $Map) { return $ordered }
    foreach ($key in @($Map.Keys | Sort-Object)) {
        $ordered[[string]$key] = [long]$Map[$key]
    }
    return $ordered
}

function Test-BenchMapEqual($Left, $Right) {
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if (-not ($Left -is [System.Collections.IDictionary]) -or -not ($Right -is [System.Collections.IDictionary])) { return $false }
    $leftKeys = @($Left.Keys | Sort-Object)
    $rightKeys = @($Right.Keys | Sort-Object)
    if (($leftKeys -join "`n") -ne ($rightKeys -join "`n")) { return $false }
    foreach ($key in $leftKeys) {
        if ([long]$Left[$key] -ne [long]$Right[$key]) { return $false }
    }
    return $true
}

function Get-BenchZonesHash($Zones) {
    $canonical = @()
    foreach ($zone in @($Zones)) {
        if ($null -eq $zone) { continue }
        $canonical += [ordered]@{ id = [int]$zone.id; name = [string]$zone.name; borough = [string]$zone.borough }
    }
    $canonical = @($canonical | Sort-Object { [int]$_.id })
    $json = ConvertTo-Json -InputObject ([object[]]$canonical) -Depth 5 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Get-BenchTail([string]$Value, [int]$Length = 4000) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value.Length -le $Length) { return $Value }
    return $Value.Substring($Value.Length - $Length)
}

function Get-BenchSnapshotReference($Loaded, $Context, [string]$SampleId) {
    $m = Get-BenchValue $Loaded 'manifest' @{}
    if ($null -eq $m) { $m = @{} }
    $s = Get-BenchValue $m 'snapshot' @{}
    if ($null -eq $s) { $s = @{} }
    $stats = Get-BenchValue $m 'stats' @{}
    if ($null -eq $stats -or -not ($stats -is [System.Collections.IDictionary])) { $stats = @{} }
    $splits = Get-BenchCanonicalMap (Get-BenchValue $s 'splits' @{})
    $features = @()
    $featureValue = Get-BenchValue $s 'feature_names' @()
    if ($null -ne $featureValue) { $features = @($featureValue | ForEach-Object { [string]$_ }) }
    $zones = @()
    $zoneValue = Get-BenchValue $m 'zones' @()
    if ($null -ne $zoneValue) { $zones = @($zoneValue) }
    return [ordered]@{
        schema_version = 'benchmark-v1'
        campaign_id = [string]$Context.campaign_id
        created_at = [datetime]::UtcNow.ToString('o')
        created_by_sample_id = $SampleId
        dataset = [ordered]@{
            id = [string](Get-BenchValue $m 'dataset_id' '')
            snapshot_sha256 = [string](Get-BenchValue $s 'sha256' '')
            source_sha256 = [string](Get-BenchValue $m 'source_sha256' '')
            catalog_sha256 = [string](Get-BenchValue $m 'catalog_sha256' '')
        }
        stats = [ordered]@{
            read = [long](Get-BenchValue $stats 'read' 0)
            accepted = [long](Get-BenchValue $stats 'accepted' 0)
            rejected = [long](Get-BenchValue $stats 'rejected' 0)
            outside_period = [long](Get-BenchValue $stats 'outside_period' 0)
            persisted = [long](Get-BenchValue $stats 'persisted' 0)
            rejection_reasons = Get-BenchCanonicalMap (Get-BenchValue $stats 'rejection_reasons' @{})
        }
        snapshot = [ordered]@{
            version = [string](Get-BenchValue $s 'version' '')
            windows = [long](Get-BenchValue $s 'windows' 0)
            examples = [long](Get-BenchValue $s 'examples' 0)
            splits = $splits
            feature_names = $features
            train_end = ConvertTo-BenchUtc ([string](Get-BenchValue $s 'train_end' ''))
            validation_end = ConvertTo-BenchUtc ([string](Get-BenchValue $s 'validation_end' ''))
            normalization = [string](Get-BenchValue $s 'normalization' '')
        }
        period = [ordered]@{
            start = ConvertTo-BenchUtc ([string](Get-BenchValue $m 'period_start' ''))
            end = ConvertTo-BenchUtc ([string](Get-BenchValue $m 'period_end_exclusive' ''))
            window_minutes = [int](Get-BenchValue $m 'window_minutes' 0)
            timezone = [string](Get-BenchValue $m 'timezone' '')
        }
        processing_version = [string](Get-BenchValue $m 'processing_version' '')
        zones_sha256 = Get-BenchZonesHash $zones
    }
}

function Test-BenchReference($Reference, $Current, $Errors) {
    if ($null -eq $Reference -or -not ($Reference -is [System.Collections.IDictionary])) {
        $Errors.Add('reference_verified: campaign reference is not an object')
        return $false
    }
    if ([string](Get-BenchValue $Reference 'schema_version' '') -ne 'benchmark-v1' -or
        [string](Get-BenchValue $Reference 'campaign_id' '') -ne [string](Get-BenchValue $Current 'campaign_id' '')) {
        $Errors.Add('reference_verified: campaign reference identity mismatch')
        return $false
    }
    $ok = $true
    $refDataset = Get-BenchValue $Reference 'dataset' @{}
    $curDataset = Get-BenchValue $Current 'dataset' @{}
    foreach ($field in @('id', 'snapshot_sha256', 'source_sha256', 'catalog_sha256')) {
        if ([string](Get-BenchValue $refDataset $field '') -ne [string](Get-BenchValue $curDataset $field '')) {
            $Errors.Add("reference_verified: dataset $field mismatch")
            $ok = $false
        }
    }
    $refSnapshot = Get-BenchValue $Reference 'snapshot' @{}
    $curSnapshot = Get-BenchValue $Current 'snapshot' @{}
    foreach ($field in @('version', 'windows', 'examples', 'train_end', 'validation_end', 'normalization')) {
        if ([string](Get-BenchValue $refSnapshot $field '') -ne [string](Get-BenchValue $curSnapshot $field '')) {
            $Errors.Add("reference_verified: snapshot $field mismatch")
            $ok = $false
        }
    }
    $refStats = Get-BenchValue $Reference 'stats' @{}
    $curStats = Get-BenchValue $Current 'stats' @{}
    foreach ($field in @('read', 'accepted', 'rejected', 'outside_period', 'persisted')) {
        if ([string](Get-BenchValue $refStats $field '') -ne [string](Get-BenchValue $curStats $field '')) {
            $Errors.Add("reference_verified: stats $field mismatch")
            $ok = $false
        }
    }
    if (-not (Test-BenchMapEqual (Get-BenchValue $refStats 'rejection_reasons' @{}) (Get-BenchValue $curStats 'rejection_reasons' @{}))) {
        $Errors.Add('reference_verified: rejection reasons mismatch')
        $ok = $false
    }
    if (-not (Test-BenchMapEqual (Get-BenchValue $refSnapshot 'splits' @{}) (Get-BenchValue $curSnapshot 'splits' @{}))) {
        $Errors.Add('reference_verified: snapshot splits mismatch')
        $ok = $false
    }
    $refFeatures = @(Get-BenchValue $refSnapshot 'feature_names' @())
    $curFeatures = @(Get-BenchValue $curSnapshot 'feature_names' @())
    if (($refFeatures -join "`n") -ne ($curFeatures -join "`n")) {
        $Errors.Add('reference_verified: snapshot feature names mismatch')
        $ok = $false
    }
    $refPeriod = Get-BenchValue $Reference 'period' @{}
    $curPeriod = Get-BenchValue $Current 'period' @{}
    foreach ($field in @('start', 'end', 'window_minutes', 'timezone')) {
        if ([string](Get-BenchValue $refPeriod $field '') -ne [string](Get-BenchValue $curPeriod $field '')) {
            $Errors.Add("reference_verified: period $field mismatch")
            $ok = $false
        }
    }
    if ([string](Get-BenchValue $Reference 'processing_version' '') -ne [string](Get-BenchValue $Current 'processing_version' '')) {
        $Errors.Add('reference_verified: processing version mismatch')
        $ok = $false
    }
    if ([string](Get-BenchValue $Reference 'zones_sha256' '') -ne [string](Get-BenchValue $Current 'zones_sha256' '')) {
        $Errors.Add('reference_verified: zone catalog hash mismatch')
        $ok = $false
    }
    return $ok
}

function New-BenchLoadSample($Context, $Sample, [datetime]$StartedAt, [datetime]$CompletedAt, [string]$Status, $Errors, $Dataset, $Timings, $Resources, $Checks, $Metrics) {
    return [ordered]@{
        schema_version = 'benchmark-v1'
        campaign_id = [string]$Context.campaign_id
        sample_id = [string]$Sample.sample_id
        case_id = [string]$Sample.case_id
        scope = [string]$Context.scope
        kind = 'load'
        repetition = [int]$Sample.repetition
        warmup = [bool]$Sample.warmup
        started_at = $StartedAt.ToString('o')
        completed_at = $CompletedAt.ToString('o')
        status = $Status
        errors = @($Errors)
        dataset = $Dataset
        timings = $Timings
        resources = $Resources
        checks = $Checks
        metrics = $Metrics
    }
}

function Write-BenchFailureArtifact($Context, $Sample, [string]$Stage, [string]$Message, $Extra = $null) {
    $rawDir = [string](Get-BenchValue $Context 'raw_dir' '')
    $campaign = [string](Get-BenchValue $Context 'campaign_id' '')
    $sampleId = [string](Get-BenchValue $Sample 'sample_id' '')
    if ([string]::IsNullOrWhiteSpace($rawDir) -or [string]::IsNullOrWhiteSpace($campaign) -or [string]::IsNullOrWhiteSpace($sampleId)) { return $null }
    $artifact = [ordered]@{
        schema_version = 'benchmark-v1'
        campaign_id = $campaign
        sample_id = $sampleId
        stage = $Stage
        error = Protect-BenchText $Message
        at = [datetime]::UtcNow.ToString('o')
    }
    if ($null -ne $Extra -and $Extra -is [System.Collections.IDictionary]) {
        foreach ($key in $Extra.Keys) {
            $value = $Extra[$key]
            if ($value -is [string]) { $value = Protect-BenchText $value }
            $artifact[[string]$key] = $value
        }
    }
    $safeSample = $sampleId -replace '[^a-zA-Z0-9-]', '_'
    $relative = "failures/$safeSample.json"
    $path = Join-Path $rawDir $relative
    if (Test-Path -LiteralPath $path) {
        $relative = "failures/$safeSample-" + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json'
        $path = Join-Path $rawDir $relative
    }
    Write-BenchJson $path $artifact
    return $path
}

function Get-BenchSnapshotHostPath($Context, [string]$ContainerPath) {
    if ([string]::IsNullOrWhiteSpace($ContainerPath)) { throw 'Loader returned an empty snapshot path.' }
    $normalized = $ContainerPath.Replace('\', '/')
    if ($normalized.StartsWith('/app/')) { $normalized = $normalized.Substring(5) }
    if (-not $normalized.StartsWith('data/')) { throw "Snapshot path is outside data/: $ContainerPath" }
    $relative = $normalized.Substring(5)
    foreach ($segment in $relative.Split('/')) {
        if ($segment -in @('', '.', '..')) { throw "Unsafe snapshot path: $ContainerPath" }
    }
    $full = Join-Path $Context.data_dir ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    return Resolve-BenchPath $full
}

function ConvertFrom-BenchComposePs([string]$Text, [string]$What) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $trimmed = $Text.Trim()
    try {
        $whole = ConvertFrom-BenchJsonData $trimmed
        if ($null -eq $whole) { return @() }
        if ($whole -is [System.Collections.IDictionary]) { return @($whole) }
        return @($whole)
    } catch { }
    $items = @()
    foreach ($line in @($trimmed -split '\r?\n' | Where-Object { $_.Trim() })) {
        try { $parsed = ConvertFrom-BenchJsonData $line } catch { throw "$What returned invalid JSON." }
        if ($parsed -isnot [System.Collections.IDictionary]) { throw "$What returned invalid JSON." }
        $items += $parsed
    }
    return $items
}

function Invoke-BenchMongo($Context, [string]$Script, [string]$LogName, [int]$TimeoutSeconds = 120) {
    $call = Invoke-BenchCompose $Context @('exec', '-T', 'mongo', 'mongosh', '--quiet', '--eval', $Script) $LogName $TimeoutSeconds
    Assert-BenchSuccess $call "MongoDB $LogName"
    return Get-BenchJsonLine $call.stdout "MongoDB $LogName"
}

function Reset-BenchDatabase($Context) {
    $nameJson = ConvertTo-Json -InputObject ([string]$Context.database) -Compress
    $script = "const name=$nameJson; const d=db.getSiblingDB(name); if (d.getName() !== name) { throw new Error('database namespace mismatch'); } d.dropDatabase(); const collections=d.getCollectionNames(); print(JSON.stringify({database:name,collections:collections}));"
    $state = Invoke-BenchMongo $Context $script 'load-reset'
    if (-not $state.Contains('database') -or -not $state.Contains('collections')) { throw 'MongoDB reset returned an incomplete state.' }
    if ([string]$state.database -ne [string]$Context.database) { throw 'MongoDB reset targeted an unexpected database.' }
    if (@($state.collections).Count -ne 0) { throw 'MongoDB benchmark database is not empty after reset.' }
    return $state
}

function Get-BenchReferencePath($Context) {
    return Resolve-BenchPath (Join-Path $Context.raw_dir 'reference/snapshot.json')
}

function Start-BenchResourceCollector($Context, $Sample, [string]$SamplePath) {
    $collector = Resolve-BenchPath $Context.config.components.resources
    if (-not (Test-Path -LiteralPath $collector -PathType Leaf)) {
        throw 'Resource collector is not available; real load samples require resource evidence.'
    }
    $directory = Resolve-BenchPath (Join-Path $Context.raw_dir 'resources') $Context.raw_dir
    [void][IO.Directory]::CreateDirectory($directory)
    $logDirectory = Resolve-BenchPath (Join-Path $Context.raw_dir 'logs') $Context.raw_dir
    [void][IO.Directory]::CreateDirectory($logDirectory)
    $output = Resolve-BenchPath (Join-Path $directory "$($Sample.sample_id).ndjson") $Context.raw_dir
    $stop = Resolve-BenchPath (Join-Path $directory "$($Sample.sample_id).stop") $Context.raw_dir
    if (Test-Path -LiteralPath $output) { throw "Resource evidence already exists: $output" }
    if (Test-Path -LiteralPath $stop) { Remove-Item -LiteralPath $stop -Force }
    $log = Resolve-BenchPath (Join-Path $logDirectory "$($Sample.sample_id)-resources") $Context.raw_dir
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    foreach ($argument in @('-NoProfile', '-File', $collector, '-ContextPath', $Context.context_path, '-SamplePath', $SamplePath, '-OutputPath', $output, '-StopFile', $stop)) {
        $start.ArgumentList.Add($argument)
    }
    $start.WorkingDirectory = Get-BenchRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    return @{ process = $process; output = $output; stop = $stop; log = $log; stdout = $stdout; stderr = $stderr }
}

function Stop-BenchResourceCollector($Collector, [int]$TimeoutSeconds = 60) {
    if ($null -eq $Collector) { return $null }
    $process = $Collector.process
    try {
        if (-not $process.HasExited) {
            [IO.File]::WriteAllText($Collector.stop, 'stop')
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            }
        }
        $stdout = Protect-BenchText ($Collector.stdout.GetAwaiter().GetResult())
        $stderr = Protect-BenchText ($Collector.stderr.GetAwaiter().GetResult())
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Collector.log))
        [IO.File]::WriteAllText($Collector.log + '.stdout.log', $stdout)
        [IO.File]::WriteAllText($Collector.log + '.stderr.log', $stderr)
        return @{ exit_code = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    } finally {
        $process.Dispose()
    }
}

function Stop-BenchLoaderContainers($Context) {
    $ids = Invoke-BenchProcess 'docker' @('ps', '-aq', '--filter', "label=com.docker.compose.project=$($Context.project)", '--filter', 'label=com.docker.compose.service=loader') 20
    Assert-BenchSuccess $ids 'Loader container inventory'
    foreach ($id in @($ids.stdout -split '\r?\n' | Where-Object { $_ })) {
        $label = Invoke-BenchProcess 'docker' @('inspect', '--format', '{{index .Config.Labels "g7.benchmark.managed"}}|{{index .Config.Labels "g7.benchmark.campaign"}}', $id) 20
        Assert-BenchSuccess $label 'Loader container ownership'
        if ($label.stdout.Trim() -ne "benchmark-v1|$($Context.campaign_id)") {
            throw 'Refusing to remove a loader container without benchmark ownership.'
        }
        $removed = Invoke-BenchProcess 'docker' @('rm', '-f', $id) 60
        Assert-BenchSuccess $removed 'Loader container cleanup'
    }
}

function Get-BenchResourcesEvidence($Context, $Sample, [string]$Path, $CollectorResult) {
    $errors = [Collections.Generic.List[string]]::new()
    $checks = [ordered]@{ resources_valid = $false }
    $empty = [ordered]@{ status = 'unavailable'; path = $null; sha256 = $null; valid_samples = 0; missing_samples = 0 }
    if ([string]::IsNullOrWhiteSpace($Path) -or $null -eq $CollectorResult) {
        $errors.Add('resource collector did not run')
        return @{ summary = $empty; checks = $checks; errors = @($errors) }
    }
    if ([int]$CollectorResult.exit_code -ne 0) {
        $errors.Add("resource collector exited with code $($CollectorResult.exit_code): $(Get-BenchTail $CollectorResult.stderr 1000)")
    }
    $path = $Path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("resource evidence is missing: $(Get-BenchTail $CollectorResult.stderr 1000)")
        return @{ summary = $empty; checks = $checks; errors = @($errors) }
    }
    $valid = 0
    $missing = 0
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadLines($path)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $isValid = $false
        try { $isValid = Test-Json -Json $line -SchemaFile (Resolve-BenchPath 'schemas/benchmark-resource.schema.json') -ErrorAction Stop } catch { $isValid = $false }
        if (-not $isValid) { $errors.Add("resource line $lineNumber is invalid"); continue }
        $observation = ConvertFrom-BenchJsonData $line
        if ([string]$observation.sample_id -ne [string]$Sample.sample_id) { $errors.Add("resource line $lineNumber belongs to another sample"); continue }
        if ($observation.available) { $valid++ } else { $missing++ }
    }
    if ($valid -lt 1) { $errors.Add('no available resource observations') }
    $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $relative = [IO.Path]::GetRelativePath((Get-BenchRoot), $path).Replace('\', '/')
    $status = if ($valid -ge 1) { 'available' } else { 'unavailable' }
    $checks.resources_valid = ($errors.Count -eq 0 -and $status -eq 'available')
    return @{
        summary = [ordered]@{ status = $status; path = $relative; sha256 = $sha; valid_samples = $valid; missing_samples = $missing }
        checks = $checks
        errors = @($errors)
    }
}

$startedAt = [datetime]::UtcNow
$context = $null
$sample = $null
$collector = $null
$collectorResult = $null
$loaderCall = $null
$loaderNeedsCleanup = $false
$artifactWritten = $false
$stage = 'preflight'
try {
    $context = Read-BenchJson $ContextPath
    $contextFull = Resolve-BenchPath $ContextPath
    if ($contextFull -ne [string]$context.context_path) { throw 'Context path does not match the campaign context.' }
    if ([string]$context.schema_version -ne 'benchmark-v1' -or [string]$context.scope -ne 'real') {
        throw 'The load adapter only runs real benchmark campaigns.'
    }
    $sampleFull = Resolve-BenchPath $SamplePath $context.raw_dir
    $sample = Read-BenchJson $sampleFull
    foreach ($key in @('schema_version', 'campaign_id', 'sample_id', 'case_id', 'kind', 'repetition', 'warmup', 'parameters')) {
        if (-not $sample.Contains($key)) { throw "Load sample is missing $key." }
    }
    if ([string]$sample.schema_version -ne 'benchmark-v1' -or [string]$sample.campaign_id -ne [string]$context.campaign_id -or [string]$sample.kind -ne 'load') {
        throw 'Load sample identity does not match the campaign.'
    }
    if ([string]$sample.sample_id -notmatch '^[a-zA-Z0-9-]+$' -or [string]$sample.case_id -notmatch '^[a-zA-Z0-9-]+$') {
        throw 'Invalid load sample/case identifier.'
    }
    if ([int]$sample.repetition -lt 1) { throw 'Invalid load repetition.' }
    $workers = [int](Get-BenchRequired $sample.parameters 'workers' 'Load sample parameters')
    if ($workers -notin @(1, 4)) { throw 'Load workers must be 1 or 4.' }
    $outputFull = Resolve-BenchPath $OutputPath $context.results_dir
    if (Test-Path -LiteralPath $outputFull) { throw 'Refusing to overwrite an existing sample.' }

    # Ownership, labels, mounts, private credentials and Compose arguments.
    $resolved = Assert-BenchCompose $context
    Assert-BenchExistingResources $context $resolved
    $gomaxprocs = [int](Get-BenchRequired $resolved.limits.loader 'gomaxprocs' 'Loader GOMAXPROCS')
    if ($gomaxprocs -ne 4) { throw 'The loader must run with GOMAXPROCS=4.' }

    $loaderConfigPath = Join-Path $context.data_dir 'configs/loader.json'
    if (-not (Test-Path -LiteralPath $loaderConfigPath -PathType Leaf)) { throw 'Generated loader configuration is missing; run Prepare first.' }
    $loaderConfig = Read-BenchJson $loaderConfigPath
    $frozen = Read-BenchJson (Resolve-BenchPath $context.config.inputs.loader)
    foreach ($key in @('name', 'source', 'source_url', 'input', 'format', 'sha256_file', 'zone_sha256_file', 'zone_catalog', 'timezone', 'period_start', 'period_end_exclusive', 'window_minutes', 'block_rows', 'batch_rows', 'mongo_uri')) {
        if ([string](Get-BenchValue $loaderConfig $key '') -cne [string](Get-BenchValue $frozen $key '')) {
            throw "Generated loader configuration changed $key."
        }
    }
    if ([string]$loaderConfig.storage -ne 'mongo' -or [string]$loaderConfig.mongo_database -ne [string]$context.database -or [string]$loaderConfig.output -ne 'data/processed') {
        throw 'Generated loader configuration has an unexpected storage, database or output.'
    }
    foreach ($key in @('input', 'zone_catalog', 'sha256_file', 'zone_sha256_file')) {
        if ([IO.Path]::IsPathRooted([string](Get-BenchValue $loaderConfig $key ''))) { throw "Loader $key must be repository-relative." }
    }
    $sourcePath = Resolve-BenchPath ([string]$loaderConfig.input)
    $catalogPath = Resolve-BenchPath ([string]$loaderConfig.zone_catalog)
    foreach ($path in @($sourcePath, $catalogPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Frozen input is missing: $path" }
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$loaderConfig.sha256_file) {
        $expected = (Get-Content -LiteralPath (Resolve-BenchPath ([string]$loaderConfig.sha256_file)) -Raw).Trim()
        if ($expected -cne $sourceHash) { throw 'Source checksum file does not match the frozen source.' }
    }
    if ([string]$loaderConfig.zone_sha256_file) {
        $expected = (Get-Content -LiteralPath (Resolve-BenchPath ([string]$loaderConfig.zone_sha256_file)) -Raw).Trim()
        if ($expected -cne $catalogHash) { throw 'Zone checksum file does not match the frozen catalog.' }
    }

    $inventory = Invoke-BenchCompose $context @('--profile', '*', 'ps', '--format', 'json') 'load-preflight'
    Assert-BenchSuccess $inventory 'Benchmark service inventory'
    $services = @(ConvertFrom-BenchComposePs $inventory.stdout 'Benchmark service inventory')
    $mongo = @($services | Where-Object {
        (Get-BenchValue $_ 'Service' '') -eq 'mongo' -and
        (Get-BenchValue $_ 'State' '') -eq 'running' -and
        (Get-BenchValue $_ 'Health' '') -eq 'healthy'
    })
    if ($mongo.Count -ne 1) { throw 'MongoDB is not running/healthy in the benchmark project.' }
    $activeJobs = @($services | Where-Object {
        (Get-BenchValue $_ 'Service' '') -in @('loader', 'trainer') -and
        (Get-BenchValue $_ 'State' '') -eq 'running'
    })
    if ($activeJobs.Count -ne 0) { throw 'A loader or trainer is already running in the benchmark project.' }
    $collectorScript = Resolve-BenchPath $context.config.components.resources
    if (-not (Test-Path -LiteralPath $collectorScript -PathType Leaf)) {
        throw 'Resource collector is not available; real load samples require resource evidence.'
    }

    # Only the fixed benchmark database is dropped, after ownership and labels
    # were validated. The demo database is never addressed.
    $stage = 'reset'
    [void](Reset-BenchDatabase $context)

    $stage = 'resources'
    $collector = Start-BenchResourceCollector $context $sample $sampleFull
    $resourcePath = $collector.output

    $stage = 'loader'
    $loaderTimeout = [Math]::Max(60, [int]$context.config.timeout_seconds - 300)
    $loaderCall = Invoke-BenchCompose $context @('--profile', 'jobs', 'run', '-T', '--rm', '--no-deps', 'loader', '-config', 'data/configs/loader.json', '-workers', [string]$workers, '-require-fresh') "logs/$($sample.sample_id)-loader" $loaderTimeout
    if ($loaderCall.exit_code -ne 0) {
        $loaderNeedsCleanup = $true
        $detail = Get-BenchTail $loaderCall.stderr 4000
        [void](Write-BenchFailureArtifact $context $sample 'loader' "Loader failed with exit code $($loaderCall.exit_code)." @{
            exit_code = $loaderCall.exit_code; stderr = $detail; stdout = (Get-BenchTail $loaderCall.stdout 4000)
            workers = $workers; timeout_seconds = $loaderTimeout
        })
        $artifactWritten = $true
        throw "Loader failed with exit code $($loaderCall.exit_code): $detail"
    }
    $collectorResult = Stop-BenchResourceCollector $collector
    $collector = $null
    $resourceEvidence = Get-BenchResourcesEvidence $context $sample $resourcePath $collectorResult

    $stage = 'loader-output'
    $loaded = ConvertFrom-BenchJsonText $loaderCall.stdout 'Loader'
    $stage = 'verify'
    $checks = [ordered]@{
        dataset_verified = $false
        result_valid = $false
        resources_valid = [bool]$resourceEvidence.checks.resources_valid
        snapshot_equivalent = $false
        fresh_load = $false
        counts_consistent = $false
        mongo_counts_match = $false
        snapshot_checksum = $false
        reference_verified = $false
    }
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($message in @($resourceEvidence.errors)) { if ($message) { $errors.Add([string]$message) } }

    $manifest = Get-BenchValue $loaded 'manifest' @{}
    if ($null -eq $manifest -or -not ($manifest -is [System.Collections.IDictionary])) {
        [void](Write-BenchFailureArtifact $context $sample 'loader-output' 'Loader returned no manifest.' @{ stdout = (Get-BenchTail $loaderCall.stdout 4000) })
        $artifactWritten = $true
        throw 'Loader returned no manifest.'
    }
    $snapshot = Get-BenchValue $manifest 'snapshot' @{}
    if ($null -eq $snapshot -or -not ($snapshot -is [System.Collections.IDictionary])) { $snapshot = @{} }
    $stats = Get-BenchValue $manifest 'stats' @{}
    if ($null -eq $stats -or -not ($stats -is [System.Collections.IDictionary])) { $stats = @{} }
    $timingsRaw = Get-BenchValue $loaded 'timings' @{}
    if ($null -eq $timingsRaw -or -not ($timingsRaw -is [System.Collections.IDictionary])) { $timingsRaw = @{} }
    $configuration = Get-BenchValue $loaded 'configuration' @{}
    if ($null -eq $configuration -or -not ($configuration -is [System.Collections.IDictionary])) { $configuration = @{} }

    $reused = [bool](Get-BenchValue $loaded 'reused' $true)
    $dataset = [ordered]@{
        id = [string](Get-BenchValue $manifest 'dataset_id' '')
        load_id = [string](Get-BenchValue $manifest 'load_id' '')
        snapshot_sha256 = [string](Get-BenchValue $snapshot 'sha256' '')
        source_sha256 = [string](Get-BenchValue $manifest 'source_sha256' '')
        catalog_sha256 = [string](Get-BenchValue $manifest 'catalog_sha256' '')
    }
    $metrics = [ordered]@{
        reused = $reused
        read = [long](Get-BenchValue $stats 'read' 0)
        accepted = [long](Get-BenchValue $stats 'accepted' 0)
        rejected = [long](Get-BenchValue $stats 'rejected' 0)
        outside_period = [long](Get-BenchValue $stats 'outside_period' 0)
        persisted = [long](Get-BenchValue $stats 'persisted' 0)
        workers = $workers
    }
    $prep = Get-BenchValue $timingsRaw 'preparation_seconds' $null
    $compute = Get-BenchValue $timingsRaw 'compute_seconds' $null
    $publication = Get-BenchValue $timingsRaw 'publication_seconds' $null
    $total = [double](Get-BenchValue $timingsRaw 'total_seconds' 0)
    $timings = [ordered]@{
        preparation_seconds = $prep
        compute_seconds = $compute
        evaluation_seconds = $null
        publication_seconds = $publication
        total_seconds = $total
    }

    try {
        Add-BenchCheck $checks $errors 'fresh_load' (-not $reused) 'loader reused a completed dataset'
        Add-BenchCheck $checks $errors 'dataset_identity' ((Test-BenchId $dataset.id '^ds-[a-f0-9]{32}$') -and (Test-BenchId $dataset.load_id '^[A-Za-z0-9_-]{1,128}$')) 'invalid dataset/load identity'
        Add-BenchCheck $checks $errors 'source_hash' ((Test-BenchHash $dataset.source_sha256) -and ($dataset.source_sha256 -ceq $sourceHash)) 'source hash does not match the frozen input'
        Add-BenchCheck $checks $errors 'catalog_hash' ((Test-BenchHash $dataset.catalog_sha256) -and ($dataset.catalog_sha256 -ceq $catalogHash)) 'catalog hash does not match the frozen catalog'
        Add-BenchCheck $checks $errors 'snapshot_hash_format' (Test-BenchHash $dataset.snapshot_sha256) 'invalid snapshot hash'
        Add-BenchCheck $checks $errors 'manifest_status' ([string](Get-BenchValue $manifest 'status' '') -ceq 'complete') 'manifest is not complete'

        $rejectionMap = Get-BenchValue $stats 'rejection_reasons' @{}
        $rejectionSum = [long]0
        if ($null -ne $rejectionMap -and $rejectionMap -is [System.Collections.IDictionary]) {
            foreach ($key in @($rejectionMap.Keys)) { $rejectionSum += [long]$rejectionMap[$key] }
        }
        $countsOk = ($metrics.read -eq ($metrics.accepted + $metrics.rejected + $metrics.outside_period)) -and
            ($metrics.persisted -eq $metrics.accepted) -and ($rejectionSum -eq $metrics.rejected) -and
            ($metrics.accepted -gt 0) -and ($metrics.accepted -gt 1000000)
        Add-BenchCheck $checks $errors 'counts_consistent' $countsOk 'load counts are inconsistent or do not exceed one million accepted trips'
        $metrics.rejection_reasons = Get-BenchCanonicalMap $rejectionMap

        $elapsed = [double](Get-BenchValue $stats 'elapsed_seconds' 0)
        $rowsPerSecond = [double](Get-BenchValue $stats 'rows_per_second' 0)
        $acceptedPerSecond = [double](Get-BenchValue $stats 'accepted_per_second' 0)
        $throughputOk = ($elapsed -gt 0) -and [double]::IsFinite($rowsPerSecond) -and [double]::IsFinite($acceptedPerSecond) -and
            (Test-BenchClose $rowsPerSecond ($metrics.read / $elapsed) 1e-9) -and
            (Test-BenchClose $acceptedPerSecond ($metrics.accepted / $elapsed) 1e-9)
        Add-BenchCheck $checks $errors 'throughput_consistent' $throughputOk 'stats throughput does not match counts/elapsed'
        $metrics.rows_per_second = $rowsPerSecond
        $metrics.accepted_per_second = $acceptedPerSecond

        $phasesOk = (Test-BenchNumber $prep) -and (Test-BenchNumber $compute) -and (Test-BenchNumber $publication)
        $timingsOk = $phasesOk -and ($null -eq (Get-BenchValue $timingsRaw 'evaluation_seconds' 'missing')) -and ($total -gt 0) -and
            (Test-BenchClose ([double]$prep + [double]$compute + [double]$publication) $total 1e-9)
        Add-BenchCheck $checks $errors 'timings_valid' $timingsOk 'invalid phase timings; evaluation must be null and phases must sum to total'

        $configOk = ([int](Get-BenchValue $configuration 'workers' 0) -eq $workers) -and
            ([int](Get-BenchValue $configuration 'gomaxprocs' 0) -eq $gomaxprocs) -and
            ([string](Get-BenchValue $configuration 'storage' '') -ceq 'mongo') -and
            ([string](Get-BenchValue $configuration 'format' '') -ceq [string]$loaderConfig.format) -and
            ([int](Get-BenchValue $configuration 'window_minutes' 0) -eq [int]$loaderConfig.window_minutes) -and
            (-not [string]::IsNullOrWhiteSpace([string](Get-BenchValue $configuration 'processing_version' ''))) -and
            ([string](Get-BenchValue $configuration 'processing_version' '') -ceq [string](Get-BenchValue $manifest 'processing_version' ''))
        Add-BenchCheck $checks $errors 'configuration_verified' $configOk 'loader configuration differs from the requested case'

        $manifestStart = ConvertTo-BenchUtc ([string](Get-BenchValue $manifest 'period_start' ''))
        $manifestEnd = ConvertTo-BenchUtc ([string](Get-BenchValue $manifest 'period_end_exclusive' ''))
        $configStart = ConvertTo-BenchUtc ([string]$loaderConfig.period_start)
        $configEnd = ConvertTo-BenchUtc ([string]$loaderConfig.period_end_exclusive)
        $manifestOk = ([string](Get-BenchValue $manifest 'name' '') -ceq [string]$loaderConfig.name) -and
            ([string](Get-BenchValue $manifest 'source' '') -ceq [string]$loaderConfig.source) -and
            ([string](Get-BenchValue $manifest 'format' '') -ceq [string]$loaderConfig.format) -and
            ([string](Get-BenchValue $manifest 'timezone' '') -ceq [string]$loaderConfig.timezone) -and
            ([int](Get-BenchValue $manifest 'window_minutes' 0) -eq [int]$loaderConfig.window_minutes) -and
            ($null -ne $manifestStart) -and ($manifestStart -ceq $configStart) -and
            ($null -ne $manifestEnd) -and ($manifestEnd -ceq $configEnd)
        Add-BenchCheck $checks $errors 'manifest_identity' $manifestOk 'manifest period/format does not match the frozen configuration'

        $zones = @(Get-BenchValue $manifest 'zones' @())
        $zoneIds = @()
        $zonesOk = $zones.Count -gt 0
        foreach ($zone in $zones) {
            if ($null -eq $zone -or -not ($zone -is [System.Collections.IDictionary])) { $zonesOk = $false; continue }
            $zoneId = [int](Get-BenchValue $zone 'id' 0)
            if ($zoneId -lt 1 -or $zoneId -gt 263 -or $zoneIds -contains $zoneId) { $zonesOk = $false }
            $zoneIds += $zoneId
            if ([string]::IsNullOrWhiteSpace([string](Get-BenchValue $zone 'name' '')) -or [string]::IsNullOrWhiteSpace([string](Get-BenchValue $zone 'borough' ''))) { $zonesOk = $false }
        }
        Add-BenchCheck $checks $errors 'zone_catalog' $zonesOk 'manifest zone catalog is empty, duplicated or out of range'

        $snapshotWindows = [long](Get-BenchValue $snapshot 'windows' 0)
        $snapshotExamples = [long](Get-BenchValue $snapshot 'examples' 0)
        $splits = Get-BenchValue $snapshot 'splits' @{}
        $features = @(Get-BenchValue $snapshot 'feature_names' @())
        $trainEnd = ConvertTo-BenchUtc ([string](Get-BenchValue $snapshot 'train_end' ''))
        $validationEnd = ConvertTo-BenchUtc ([string](Get-BenchValue $snapshot 'validation_end' ''))
        $snapshotVersion = [string](Get-BenchValue $snapshot 'version' '')
        $normalization = [string](Get-BenchValue $snapshot 'normalization' '')
        $slotCount = [long]0
        if ($null -ne $configStart -and $null -ne $configEnd) {
            $slotCount = [long](([datetimeoffset]::Parse($configEnd) - [datetimeoffset]::Parse($configStart)).TotalMinutes / [int]$loaderConfig.window_minutes)
        }
        $zoneCount = $zoneIds.Count
        $expectedWindows = $slotCount * $zoneCount
        $expectedExamples = [Math]::Max(0, $slotCount - 1) * $zoneCount
        $trainSlots = [long]($slotCount * 70 / 100)
        $validSlots = [long]($slotCount * 85 / 100)
        $expectedTrain = [Math]::Max(0, $trainSlots - 1) * $zoneCount
        $expectedValidation = [Math]::Max(0, $validSlots - $trainSlots) * $zoneCount
        $expectedTest = [Math]::Max(0, $slotCount - $validSlots) * $zoneCount
        $featuresOk = ($features.Count -gt 0) -and (@($features | Select-Object -Unique).Count -eq $features.Count) -and (@($features | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0)
        $splitOk = ($null -ne $splits -and $splits -is [System.Collections.IDictionary]) -and
            ((@($splits.Keys | Sort-Object) -join ',') -ceq 'test,train,validation') -and
            ([long]$splits['train'] -eq $expectedTrain) -and
            ([long]$splits['validation'] -eq $expectedValidation) -and
            ([long]$splits['test'] -eq $expectedTest) -and
            (([long]$splits['train'] + [long]$splits['validation'] + [long]$splits['test']) -eq $snapshotExamples)
        $snapshotMetaOk = ($snapshotWindows -eq $expectedWindows) -and ($snapshotExamples -eq $expectedExamples) -and $splitOk -and $featuresOk -and
            (-not [string]::IsNullOrWhiteSpace($snapshotVersion)) -and (-not [string]::IsNullOrWhiteSpace($normalization)) -and
            ($null -ne $trainEnd) -and ($null -ne $validationEnd) -and ($null -ne $configStart) -and ($null -ne $configEnd) -and
            ([datetimeoffset]::Parse($trainEnd) -gt [datetimeoffset]::Parse($configStart)) -and
            ([datetimeoffset]::Parse($validationEnd) -gt [datetimeoffset]::Parse($trainEnd)) -and
            ([datetimeoffset]::Parse($configEnd) -ge [datetimeoffset]::Parse($validationEnd))
        Add-BenchCheck $checks $errors 'snapshot_metadata' $snapshotMetaOk 'snapshot windows/examples/splits/metadata are inconsistent'
        $metrics.snapshot_windows = $snapshotWindows
        $metrics.snapshot_examples = $snapshotExamples
        $metrics.snapshot_splits = Get-BenchCanonicalMap $splits

        $snapshotPath = [string](Get-BenchValue $snapshot 'path' '')
        $snapshotHost = $null
        $snapshotBytes = [long]0
        $snapshotFileHash = ''
        try {
            $snapshotHost = Get-BenchSnapshotHostPath $context $snapshotPath
            if (Test-Path -LiteralPath $snapshotHost -PathType Leaf) {
                $snapshotBytes = (Get-Item -LiteralPath $snapshotHost).Length
                $snapshotFileHash = (Get-FileHash -LiteralPath $snapshotHost -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        } catch { $errors.Add("snapshot: $($_.Exception.Message)") }
        Add-BenchCheck $checks $errors 'snapshot_checksum' (($snapshotBytes -gt 0) -and ($snapshotFileHash -ceq $dataset.snapshot_sha256)) 'snapshot file is missing or does not match its manifest hash'
        $metrics.snapshot_path = $snapshotPath
        $metrics.snapshot_bytes = $snapshotBytes

        $mongoScript = @'
const d=db.getSiblingDB(__NAME__);
const id=__ID__;
const load=__LOAD__;
const m=d.datasets.findOne({_id:id});
const cur=d.settings.findOne({_id:"current_dataset"});
const trips=d.trips.countDocuments({load_id:load});
const windows=d.windows.countDocuments({load_id:load});
const allTrips=d.trips.countDocuments({});
const allWindows=d.windows.countDocuments({});
const tripDataset=d.trips.countDocuments({load_id:load,dataset_id:id});
const windowDataset=d.windows.countDocuments({load_id:load,dataset_id:id});
const agg=d.windows.aggregate([{$match:{load_id:load}},{$group:{_id:null,total:{$sum:"$observed_trips"}}}]).toArray();
print(JSON.stringify({manifest:m?{id:m._id,load_id:m.load_id,status:m.status,source_sha256:m.source_sha256,catalog_sha256:m.catalog_sha256,snapshot_sha256:m.snapshot?m.snapshot.sha256:null,snapshot_windows:m.snapshot?Number(m.snapshot.windows):null,accepted:m.stats?Number(m.stats.accepted):null,persisted:m.stats?Number(m.stats.persisted):null}:null,current:cur?cur.dataset_id:null,trips:trips,windows:windows,all_trips:allTrips,all_windows:allWindows,trip_dataset:tripDataset,window_dataset:windowDataset,window_sum:agg.length?Number(agg[0].total):0}));
'@
        $mongoScript = $mongoScript.Replace('__NAME__', (ConvertTo-Json -InputObject ([string]$context.database) -Compress)).Replace('__ID__', (ConvertTo-Json -InputObject $dataset.id -Compress)).Replace('__LOAD__', (ConvertTo-Json -InputObject $dataset.load_id -Compress))
        $mongoState = Invoke-BenchMongo $context $mongoScript 'load-verify'
        $mongoManifest = Get-BenchValue $mongoState 'manifest' $null
        $mongoManifestOk = ($null -ne $mongoManifest -and $mongoManifest -is [System.Collections.IDictionary]) -and
            ([string]$mongoManifest.id -ceq $dataset.id) -and
            ([string]$mongoManifest.load_id -ceq $dataset.load_id) -and
            ([string]$mongoManifest.status -ceq 'complete') -and
            ([string]$mongoManifest.source_sha256 -ceq $dataset.source_sha256) -and
            ([string]$mongoManifest.catalog_sha256 -ceq $dataset.catalog_sha256) -and
            ([string]$mongoManifest.snapshot_sha256 -ceq $dataset.snapshot_sha256) -and
            ([long]$mongoManifest.snapshot_windows -eq $snapshotWindows) -and
            ([long]$mongoManifest.accepted -eq $metrics.accepted) -and
            ([long]$mongoManifest.persisted -eq $metrics.persisted)
        Add-BenchCheck $checks $errors 'mongo_manifest' $mongoManifestOk 'MongoDB manifest differs from the loader result'
        $mongoCountsOk = ([string]$mongoState.current -ceq $dataset.id) -and
            ([long]$mongoState.trips -eq $metrics.accepted) -and
            ([long]$mongoState.windows -eq $snapshotWindows) -and
            ([long]$mongoState.all_trips -eq $metrics.accepted) -and
            ([long]$mongoState.all_windows -eq $snapshotWindows) -and
            ([long]$mongoState.trip_dataset -eq $metrics.accepted) -and
            ([long]$mongoState.window_dataset -eq $snapshotWindows) -and
            ([long]$mongoState.window_sum -eq $metrics.accepted)
        Add-BenchCheck $checks $errors 'mongo_counts_match' $mongoCountsOk 'MongoDB counts/window sums do not match accepted trips'
        $metrics.mongo_trips = [long]$mongoState.trips
        $metrics.mongo_windows = [long]$mongoState.windows
        $metrics.window_sum = [long]$mongoState.window_sum

        $currentReference = Get-BenchSnapshotReference $loaded $context $sample.sample_id
        $referencePath = Get-BenchReferencePath $context
        $reference = $null
        if (Test-Path -LiteralPath $referencePath -PathType Leaf) {
            try { $reference = Read-BenchJson $referencePath } catch { $errors.Add("reference: $($_.Exception.Message)") }
        }
        if ($null -ne $reference) {
            $referenceOk = Test-BenchReference $reference $currentReference $errors
            Add-BenchCheck $checks $errors 'reference_verified' $referenceOk 'campaign reference differs from this load'
        } elseif ($errors.Count -eq 0) {
            Write-BenchJson $referencePath $currentReference
            $checks.reference_verified = $true
            $checks.reference_established = $true
        }

        Add-BenchCheck $checks $errors 'snapshot_equivalent' ($checks.snapshot_checksum -and $checks.reference_verified) 'snapshot is not equivalent to the campaign reference'
        $checks.dataset_verified = ($checks.fresh_load -and $checks.dataset_identity -and $checks.source_hash -and $checks.catalog_hash -and
            $checks.snapshot_hash_format -and $checks.manifest_status -and $checks.manifest_identity -and $checks.zone_catalog -and
            $checks.snapshot_checksum -and $checks.mongo_manifest -and $checks.mongo_counts_match)
        $checks.result_valid = ($checks.counts_consistent -and $checks.throughput_consistent -and $checks.timings_valid -and
            $checks.configuration_verified -and $checks.snapshot_metadata)
        $checks.resources_valid = [bool]$resourceEvidence.checks.resources_valid
        $metrics.dataset_id = $dataset.id
        $metrics.load_id = $dataset.load_id
        $metrics.source_sha256 = $dataset.source_sha256
        $metrics.catalog_sha256 = $dataset.catalog_sha256
    } catch {
        $errors.Add("verification: $($_.Exception.Message)")
    }

    $status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
    $completedAt = [datetime]::UtcNow
    $stage = 'sample-build'
    $sampleResult = New-BenchLoadSample $context $sample $startedAt $completedAt $status $errors $dataset $timings $resourceEvidence.summary $checks $metrics
    $sampleJson = ConvertTo-Json -InputObject $sampleResult -Depth 40
    $schemaValid = $false
    try { $schemaValid = Test-Json -Json $sampleJson -SchemaFile $context.result_schema -ErrorAction Stop } catch { $schemaValid = $false }
    if (-not $schemaValid) {
        [void](Write-BenchFailureArtifact $context $sample 'sample' 'Constructed load sample failed schema validation.' @{ sample = $sampleResult })
        $artifactWritten = $true
        $stage = 'sample'
        throw 'Constructed load sample failed schema validation.'
    }
    Write-BenchJson $outputFull $sampleResult
    $stage = 'sample'
    if ($status -ne 'passed') {
        $summary = (@($errors) | Select-Object -First 5) -join '; '
        throw "Load verification failed: $summary"
    }
} catch {
    $message = Protect-BenchText $_.Exception.Message
    if ($null -ne $context -and $null -ne $sample -and -not $artifactWritten -and $stage -notin @('verify', 'sample')) {
        [void](Write-BenchFailureArtifact $context $sample $stage $message)
    }
    throw
} finally {
    if ($null -ne $collector) {
        try { [void](Stop-BenchResourceCollector $collector) } catch { }
        $collector = $null
    }
    if ($loaderNeedsCleanup -and $null -ne $context) {
        try { Stop-BenchLoaderContainers $context } catch { }
    }
}
