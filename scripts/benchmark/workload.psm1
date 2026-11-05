#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'statistics.psm1') -DisableNameChecking
function Open-BenchWorkload([string]$ContextPath,[string]$SamplePath,[string]$OutputPath,[string]$Kind) {
    $c=Read-BenchJson $ContextPath
    Assert-BenchOwnership $c
    if($c.scope -ne 'real' -or (Resolve-BenchPath $ContextPath) -ne $c.context_path){throw 'Invalid real workload context.'}
    $s=Read-BenchJson (Resolve-BenchPath $SamplePath $c.raw_dir)
    $plan=@(Read-BenchJson (Join-Path $c.results_dir 'plan.json'))
    $matched=@($plan|Where-Object sample_id -CEQ $s.sample_id)
    if($matched.Count -ne 1 -or $s.kind -ne $Kind -or (ConvertTo-BenchCanonicalJson $matched[0]) -cne (ConvertTo-BenchCanonicalJson $s)){throw 'Unknown or modified sample plan.'}
    [void](Resolve-BenchPath $OutputPath $c.results_dir)
    if(Test-Path -LiteralPath $OutputPath){throw 'Refusing to overwrite a sample.'}
    $resolved=Assert-BenchCompose $c
    Assert-BenchExistingResources $c $resolved
    return @{context=$c;sample=$s}
}
function Get-BenchSHA256([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Get-BenchRelativePath([string]$Path){return [IO.Path]::GetRelativePath((Get-BenchRoot),$Path).Replace('\','/')}
function Get-BenchCurrentDataset($Context,[string]$SampleId){
    $query='const d=db.getSiblingDB("g7_benchmark");const c=d.settings.findOne({_id:"current_dataset"});const m=c?d.datasets.findOne({_id:c.dataset_id,status:"complete"}):null;if(!m)throw Error("no complete benchmark dataset");m.dataset_id=m._id;print(JSON.stringify(m));'
    $call=Invoke-BenchCompose $Context @('exec','-T','mongo','mongosh','--quiet','--eval',$query) "logs/$SampleId-dataset" 30
    Assert-BenchSuccess $call 'Current benchmark dataset'
    $m=ConvertFrom-BenchJsonData $call.stdout
    if($m.stats.accepted -le 1000000){throw 'Real workload requires over one million accepted trips.'}
    return $m
}
function Get-BenchDatasetIdentity($Manifest){return @{id=$Manifest.dataset_id;load_id=$Manifest.load_id;snapshot_sha256=$Manifest.snapshot.sha256;source_sha256=$Manifest.source_sha256;catalog_sha256=$Manifest.catalog_sha256}}
function New-BenchSession($Context){
    $secrets=Get-BenchSecrets $Context
    $login=Invoke-RestMethod ($Context.api_url+'/api/v1/auth/login') -Method Post -ContentType application/json -Body (@{username='benchmark';password=$secrets.BENCH_PASSWORD}|ConvertTo-Json) -TimeoutSec 10
    return @{Authorization="Bearer $($login.access_token)"}
}
function Close-BenchSession($Context,$Headers){
    Invoke-RestMethod ($Context.api_url+'/api/v1/auth/logout') -Method Post -Headers $Headers -ContentType application/json -Body '{}' -TimeoutSec 10 | Out-Null
}
function New-BenchWorkloadResult($Context,$Sample,[datetime]$Started,$Dataset,$Timings,$Resources,$Metrics){
    return @{
        schema_version='benchmark-v1';campaign_id=$Context.campaign_id;scope=$Context.scope
        sample_id=$Sample.sample_id;case_id=$Sample.case_id;kind=$Sample.kind;repetition=$Sample.repetition;warmup=$Sample.warmup
        started_at=$Started.ToString('o');completed_at=[datetime]::UtcNow.ToString('o');status='passed';errors=@()
        dataset=$Dataset;timings=$Timings;resources=$Resources;metrics=$Metrics
        checks=@{dataset_verified=$true;result_valid=$true;resources_valid=$true}
    }
}
function Get-BenchTail([string]$Text,[int]$Length=2000) { if($Text.Length -le $Length){return $Text}; return $Text.Substring($Text.Length-$Length) }
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


