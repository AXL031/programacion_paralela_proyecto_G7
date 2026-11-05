#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:BenchSecrets = @()

function Get-BenchRoot { (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path }

function Resolve-BenchPath([string]$Path, [string]$Root = (Get-BenchRoot), [switch]$AllowRoot) {
    $base = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $full = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $base $Path)) }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, $comparison) -and -not ($AllowRoot -and $full.Equals($base, $comparison))) {
        throw "Path outside authorized directory: $Path"
    }
    # Reject junctions/symlinks, including an existing parent of a new output.
    $cursor = $full
    while ($cursor.Length -ge $base.Length) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in benchmark paths: $cursor"
            }
        }
        if ($cursor.Equals($base, $comparison)) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Write-BenchJson([string]$Path, $Value) {
    $full = Resolve-BenchPath $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    $temporary = $full + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $full -Force
}

function Read-BenchJson([string]$Path) {
    Get-Content -LiteralPath (Resolve-BenchPath $Path) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
}

function Protect-BenchText([string]$Value) {
    foreach ($secret in $script:BenchSecrets) {
        if ($secret) { $Value = $Value.Replace($secret, '[REDACTED]') }
    }
    return $Value
}

function Invoke-BenchProcess {
    param([string]$File, [string[]]$Arguments, [int]$TimeoutSeconds = 1800, [string]$LogPrefix = '')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $File
    $start.WorkingDirectory = Get-BenchRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) { $process.Kill($true); $process.WaitForExit() }
        $stdout = Protect-BenchText ($output.GetAwaiter().GetResult())
        $stderr = Protect-BenchText ($errors.GetAwaiter().GetResult())
        $code = if ($timedOut) { 124 } else { $process.ExitCode }
        if ($timedOut) { $stderr += "`nProcess timeout after $TimeoutSeconds seconds." }
    } finally { $clock.Stop(); $process.Dispose() }
    if ($LogPrefix) {
        $prefix = Resolve-BenchPath $LogPrefix
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($prefix))
        [IO.File]::WriteAllText($prefix + '.stdout.log', $stdout)
        [IO.File]::WriteAllText($prefix + '.stderr.log', $stderr)
    }
    return @{ exit_code = $code; stdout = $stdout; stderr = $stderr; elapsed_seconds = $clock.Elapsed.TotalSeconds }
}

function Assert-BenchSuccess($Result, [string]$Operation) {
    if ($Result.exit_code -ne 0) {
        $message = $Result.stderr
        if ($message.Length -gt 2000) { $message = $message.Substring($message.Length - 2000) }
        throw "$Operation failed ($($Result.exit_code)): $message"
    }
}

function Get-BenchConfiguration([string]$Path) {
    $config = Read-BenchJson $Path
    foreach ($key in @('schema_version', 'scope', 'seed', 'api_port', 'initial_workers', 'timeout_seconds', 'inputs', 'protocol', 'components')) {
        if (-not $config.ContainsKey($key)) { throw "Configuration missing $key" }
    }
    if ($config.schema_version -ne 'benchmark-v1' -or $config.scope -notin @('real', 'orchestrator_fixture')) { throw 'Invalid version/scope.' }
    foreach ($key in @('seed', 'api_port', 'initial_workers', 'timeout_seconds')) {
        if ($config[$key] -isnot [long] -and $config[$key] -isnot [int]) { throw "$key must be an integer." }
    }
    if ($config.api_port -lt 1024 -or $config.api_port -gt 65535 -or $config.api_port -in @(3000, 8080)) { throw 'Use a separate unprivileged API port.' }
    if ($config.initial_workers -notin @(1, 2, 4) -or $config.timeout_seconds -lt 1 -or $config.timeout_seconds -gt 3600) { throw 'Invalid workers/timeout.' }
    foreach ($key in @('loader', 'training')) {
        if (-not $config.inputs.ContainsKey($key) -or -not (Test-Path -LiteralPath (Resolve-BenchPath $config.inputs[$key]) -PathType Leaf)) { throw "Missing $key input." }
    }
    $p = $config.protocol
    foreach ($key in @('warmups', 'repetitions', 'loader_workers', 'training_workers', 'api_passes', 'api_requests', 'api_concurrency', 'api_cache', 'absolute_tolerance', 'relative_tolerance', 'api_p95_objective_ms')) {
        if (-not $p.ContainsKey($key)) { throw "Protocol missing $key" }
    }
    foreach ($key in @('warmups', 'repetitions', 'api_passes', 'api_requests')) {
        if (($p[$key] -isnot [long] -and $p[$key] -isnot [int]) -or $p[$key] -lt 0) { throw "Invalid integer $key" }
    }
    if ($p.repetitions -lt 1 -or $p.api_passes -lt 1 -or $p.api_requests -lt 1) { throw 'Repetition/request counts must be positive.' }
    foreach ($key in @('loader_workers', 'training_workers', 'api_concurrency', 'api_cache')) {
        if (@($p[$key]).Count -eq 0 -or @($p[$key] | Select-Object -Unique).Count -ne @($p[$key]).Count) { throw "Invalid/duplicate cases: $key" }
    }
    foreach ($n in $p.loader_workers) { if ($n -notin @(1, 4)) { throw 'Invalid loader case.' } }
    foreach ($n in $p.training_workers) { if ($n -notin @(1, 2, 4)) { throw 'Invalid training case.' } }
    foreach ($n in $p.api_concurrency) { if ($n -notin @(1, 10, 25)) { throw 'Invalid API concurrency.' } }
    foreach ($n in $p.api_cache) { if ($n -notin @('cold', 'warm', 'unavailable')) { throw 'Invalid cache case.' } }
    foreach ($key in @('absolute_tolerance', 'relative_tolerance', 'api_p95_objective_ms')) {
        if ($p[$key] -is [string] -or -not [double]::IsFinite([double]$p[$key]) -or $p[$key] -le 0) { throw "Invalid $key" }
    }
    foreach ($kind in @('load', 'training', 'api', 'resources', 'summary')) {
        if (-not $config.components.ContainsKey($kind)) { throw "Missing $kind adapter definition." }
        [void](Resolve-BenchPath $config.components[$kind])
    }
    if ($config.scope -eq 'real') {
        # A small synthetic/test configuration cannot silently become a real campaign.
        $reference = Read-BenchJson 'configs/benchmark.json'
        foreach ($key in $reference.protocol.Keys) {
            if (($p[$key] | ConvertTo-Json -Compress) -ne ($reference.protocol[$key] | ConvertTo-Json -Compress)) { throw "Real protocol changed: $key; agree on a new protocol version before measuring." }
        }
        foreach ($kind in $reference.components.Keys) {
            if ($config.components[$kind] -ne $reference.components[$kind]) { throw "Unexpected real adapter: $kind" }
        }
        if ($config.inputs.loader -ne 'configs/demo.json' -or $config.inputs.training -ne 'configs/training.json') { throw 'Real campaigns require the agreed inputs.' }
    } else {
        foreach ($path in $config.components.Values) {
            [void](Resolve-BenchPath (Resolve-BenchPath $path) (Join-Path (Get-BenchRoot) 'tests/benchmark/fixtures'))
        }
    }
    return $config
}

function New-BenchPlan($Config, [string]$Campaign) {
    $samples = [Collections.Generic.List[object]]::new()
    $p = $Config.protocol
    $groups = @(
        @{ kind = 'load'; cases = @($p.loader_workers | ForEach-Object { @{ id = "L$_"; workers = $_ } }) },
        @{ kind = 'training'; cases = @(@{ id = 'S'; workers = 1; mode = 'sequential' }) + @($p.training_workers | ForEach-Object { @{ id = "D$_"; workers = $_; mode = 'distributed' } }) }
    )
    foreach ($group in $groups) {
        for ($round = 1; $round -le ($p.warmups + $p.repetitions); $round++) {
            $warmup = $round -le $p.warmups
            $repetition = if ($warmup) { $round } else { $round - $p.warmups }
            $cases = @($group.cases)
            $offset = (($Config.seed % $cases.Count) + $round - 1) % $cases.Count
            for ($j = 0; $j -lt $cases.Count; $j++) {
                $case = $cases[($j + $offset) % $cases.Count]
                $tag = if ($warmup) { 'w' } else { 'r' }
                $samples.Add(@{ schema_version = 'benchmark-v1'; campaign_id = $Campaign; sample_id = "$($case.id)-$tag$repetition"; case_id = $case.id; kind = $group.kind; repetition = $repetition; warmup = $warmup; parameters = $case })
            }
        }
    }
    $apiCases = @()
    foreach ($cache in $p.api_cache) {
        foreach ($n in $p.api_concurrency) { $apiCases += @{ id = "API-$cache-c$n"; cache = $cache; concurrency = $n; requests = $p.api_requests } }
    }
    for ($round = 1; $round -le $p.api_passes; $round++) {
        $offset = (($Config.seed % $apiCases.Count) + $round - 1) % $apiCases.Count
        for ($j = 0; $j -lt $apiCases.Count; $j++) {
            $case = $apiCases[($j + $offset) % $apiCases.Count]
            $samples.Add(@{ schema_version = 'benchmark-v1'; campaign_id = $Campaign; sample_id = "$($case.id)-r$round"; case_id = $case.id; kind = 'api'; repetition = $round; warmup = $false; parameters = $case })
        }
    }
    return @($samples.ToArray())
}

function Get-BenchMissingComponents($Config) {
    @($Config.components.Keys | Sort-Object | Where-Object { -not (Test-Path -LiteralPath (Resolve-BenchPath $Config.components[$_]) -PathType Leaf) })
}

function Get-BenchReference {
    $git = Invoke-BenchProcess 'git' @('rev-parse', 'HEAD') 20
    Assert-BenchSuccess $git 'git reference'
    $diff = Invoke-BenchProcess 'git' @('diff', '--binary', 'HEAD') 20
    Assert-BenchSuccess $diff 'git diff'
    $status = Invoke-BenchProcess 'git' @('status', '--porcelain=v1', '--untracked-files=all') 20
    Assert-BenchSuccess $status 'git status'
    $sources = Invoke-BenchProcess 'git' @('ls-files', '--cached', '--others', '--exclude-standard', '--', 'cmd', 'internal', 'scripts', 'configs', 'schemas', 'deploy', 'tests', 'docker-compose.benchmark.yml', 'go.mod', 'go.sum') 20
    Assert-BenchSuccess $sources 'source inventory'
    $hashes = [ordered]@{}
    foreach ($file in @($sources.stdout -split '\r?\n' | Where-Object { $_ } | Sort-Object -Unique)) {
        $full = Resolve-BenchPath $file
        if (Test-Path -LiteralPath $full -PathType Leaf) { $hashes[$file] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $diffHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($diff.stdout))).ToLowerInvariant()
    return @{ commit = $git.stdout.Trim(); dirty = -not [string]::IsNullOrWhiteSpace($status.stdout); diff_sha256 = $diffHash; source_files = $hashes }
}

function Initialize-BenchCampaign([string]$Campaign, [string]$ConfigPath) {
    if ($Campaign -cnotmatch '^[a-z0-9][a-z0-9-]{2,31}$') { throw 'Campaign must use 3–32 lowercase letters/digits/hyphens.' }
    $config = Get-BenchConfiguration $ConfigPath
    $resultDir = Resolve-BenchPath "bench/results/$Campaign"
    $rawDir = Resolve-BenchPath "bench/raw/$Campaign"
    $dataDir = Resolve-BenchPath "data/bench/$Campaign"
    $privateDir = Resolve-BenchPath ".cache/benchmark/$Campaign"
    $contextPath = Join-Path $privateDir 'context.json'
    $configHash = (Get-FileHash -LiteralPath (Resolve-BenchPath $ConfigPath)).Hash.ToLowerInvariant()
    if (Test-Path -LiteralPath $contextPath) {
        $context = Read-BenchJson $contextPath
        if ($context.config_sha256 -ne $configHash -or $context.campaign_id -ne $Campaign -or $context.repo_root -ne (Get-BenchRoot)) { throw 'Campaign/configuration ownership mismatch. Use a new campaign.' }
        if (($context.config | ConvertTo-Json -Depth 30 -Compress) -cne ($config | ConvertTo-Json -Depth 30 -Compress) -or $context.scope -ne $config.scope) { throw 'Private context configuration was modified.' }
        $frozen = Read-BenchJson (Join-Path $resultDir 'reference.json')
        $current = Get-BenchReference
        if (($frozen.source_files | ConvertTo-Json -Compress) -ne ($current.source_files | ConvertTo-Json -Compress)) { throw 'Source files changed since freezing the campaign. Use a new campaign.' }
    } else {
        foreach ($dir in @($resultDir, $rawDir, $dataDir, $privateDir)) {
            if (Test-Path -LiteralPath $dir) { throw "Refusing to adopt an existing directory: $dir" }
            [void][IO.Directory]::CreateDirectory($dir)
        }
        $context = [ordered]@{
            schema_version = 'benchmark-v1'; campaign_id = $Campaign; scope = $config.scope
            project = "transporte-g7-bench-$Campaign"; database = 'g7_benchmark'
            repo_root = Get-BenchRoot; config_path = (Resolve-BenchPath $ConfigPath); config_sha256 = $configHash
            results_dir = $resultDir; raw_dir = $rawDir; data_dir = $dataDir
            env_file = (Join-Path $privateDir 'compose.env'); context_path = $contextPath
            api_url = "http://127.0.0.1:$($config.api_port)"; result_schema = (Resolve-BenchPath 'schemas/benchmark-result.schema.json')
            config = $config
            compose_arguments = @('compose', '--project-directory', (Get-BenchRoot), '--env-file', (Join-Path $privateDir 'compose.env'), '-p', "transporte-g7-bench-$Campaign", '-f', (Resolve-BenchPath 'docker-compose.benchmark.yml'))
        }
        Write-BenchJson $contextPath $context
        Write-BenchJson (Join-Path $dataDir '.g7-benchmark.json') @{ campaign_id = $Campaign; project = $context.project; schema_version = 'benchmark-v1' }
        Write-BenchJson (Join-Path $resultDir 'reference.json') (Get-BenchReference)
        Write-BenchJson (Join-Path $resultDir 'config.json') $config
        Write-BenchJson (Join-Path $resultDir 'plan.json') @(New-BenchPlan $config $Campaign)
        Write-BenchJson (Join-Path $resultDir 'manifest.json') @{
            schema_version = 'benchmark-v1'; campaign_id = $Campaign; scope = $config.scope
            project = $context.project; created_at = [datetime]::UtcNow.ToString('o'); state = 'planned'
            samples = @(); errors = @(); missing_components = @(Get-BenchMissingComponents $config)
            pending_issues = @(2, 3, 4, 5); objective_evaluated = $false
        }
    }
    return $context
}

function Get-BenchSecrets($Context) {
    $envPath = Resolve-BenchPath $Context.env_file
    if (-not (Test-Path -LiteralPath $envPath)) {
        $values = [ordered]@{
            BENCH_CAMPAIGN = $Context.campaign_id; BENCH_PROJECT = $Context.project
            BENCH_DATA_DIR = $Context.data_dir.Replace('\', '/'); BENCH_API_PORT = [string]$Context.config.api_port
        }
        foreach ($key in @('BENCH_MASTER_TOKEN', 'BENCH_JWT_SECRET', 'BENCH_PASSWORD')) {
            $values[$key] = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
        }
        [IO.File]::WriteAllLines($envPath, @($values.Keys | ForEach-Object { "$_='$($values[$_])'" }))
    }
    $secrets = @{}
    foreach ($line in [IO.File]::ReadAllLines($envPath)) {
        if ($line -match "^(BENCH_[A-Z_]+)='([^']*)'$" ) { $secrets[$Matches[1]] = $Matches[2] }
    }
    foreach ($key in @('BENCH_MASTER_TOKEN', 'BENCH_JWT_SECRET', 'BENCH_PASSWORD')) {
        if (-not $secrets.ContainsKey($key) -or $secrets[$key].Length -lt 32) { throw 'Invalid private benchmark credentials.' }
    }
    $script:BenchSecrets = @($secrets.BENCH_MASTER_TOKEN, $secrets.BENCH_JWT_SECRET, $secrets.BENCH_PASSWORD)
    return $secrets
}

function Invoke-BenchCompose($Context, [string[]]$Arguments, [string]$LogName = '', [int]$TimeoutSeconds = 1800) {
    $prefix = if ($LogName) { Join-Path $Context.raw_dir $LogName } else { '' }
    Invoke-BenchProcess 'docker' (@($Context.compose_arguments) + $Arguments) $TimeoutSeconds $prefix
}

function Assert-BenchOwnership($Context) {
    if ($Context.campaign_id -cnotmatch '^[a-z0-9][a-z0-9-]{2,31}$') { throw 'Invalid campaign ownership identity.' }
    if ($Context.project -cne "transporte-g7-bench-$($Context.campaign_id)" -or $Context.database -ne 'g7_benchmark' -or $Context.repo_root -ne (Get-BenchRoot)) { throw 'Invalid benchmark namespace.' }
    if ($Context.result_schema -ne (Resolve-BenchPath 'schemas/benchmark-result.schema.json') -or $Context.schema_version -ne 'benchmark-v1') { throw 'Unexpected result contract.' }
    foreach ($entry in @{
        results_dir = "bench/results/$($Context.campaign_id)"
        raw_dir = "bench/raw/$($Context.campaign_id)"
        env_file = ".cache/benchmark/$($Context.campaign_id)/compose.env"
        context_path = ".cache/benchmark/$($Context.campaign_id)/context.json"
    }.GetEnumerator()) {
        if ($Context[$entry.Key] -ne (Resolve-BenchPath $entry.Value)) { throw "Invalid owned path: $($entry.Key)" }
    }
    $expected = Resolve-BenchPath "data/bench/$($Context.campaign_id)"
    if ($Context.data_dir -ne $expected) { throw 'Invalid campaign data directory.' }
    $owner = Read-BenchJson (Join-Path $expected '.g7-benchmark.json')
    if ($owner.project -ne $Context.project -or $owner.campaign_id -ne $Context.campaign_id -or $owner.schema_version -ne 'benchmark-v1') { throw 'Campaign ownership marker does not match.' }
    $canonical = @('compose', '--project-directory', (Get-BenchRoot), '--env-file', $Context.env_file, '-p', $Context.project, '-f', (Resolve-BenchPath 'docker-compose.benchmark.yml'))
    if (($Context.compose_arguments | ConvertTo-Json -Compress) -ne ($canonical | ConvertTo-Json -Compress)) { throw 'Unexpected Compose command/context.' }
    [void](Resolve-BenchPath $Context.env_file (Resolve-BenchPath ".cache/benchmark/$($Context.campaign_id)"))
}

function Assert-BenchCompose($Context) {
    Assert-BenchOwnership $Context
    [void](Get-BenchSecrets $Context)
    $resolved = Invoke-BenchCompose $Context @('--profile', '*', 'config', '--format', 'json')
    Assert-BenchSuccess $resolved 'Compose resolution'
    # Never save this raw object: its environment contains private credentials.
    $compose = $resolved.stdout | ConvertFrom-Json -AsHashtable
    if ($compose.name -ne $Context.project) { throw 'Compose project mismatch (including BENCH_* environment overrides).' }
    $allowed = @('mongo', 'redis', 'master', 'worker', 'api', 'loader', 'trainer', 'dev')
    if (@($compose.services.Keys).Count -ne $allowed.Count) { throw 'Unexpected Compose services.' }
    $limits = [ordered]@{}
    foreach ($name in $allowed) {
        if (-not $compose.services.ContainsKey($name)) { throw "Missing service $name" }
        $service = $compose.services[$name]
        if ($service.labels['g7.benchmark.managed'] -ne 'benchmark-v1' -or $service.labels['g7.benchmark.campaign'] -ne $Context.campaign_id) { throw 'Invalid service ownership labels.' }
        if (-not $service.ContainsKey('cpus') -or $service.cpus -le 0 -or -not $service.ContainsKey('mem_limit') -or $service.mem_limit -le 0) { throw "Missing CPU/memory limits: $name" }
        if ($service.ContainsKey('environment') -and $service.environment.ContainsKey('MONGO_DATABASE') -and $service.environment.MONGO_DATABASE -ne $Context.database) { throw 'Unexpected MongoDB database.' }
        if ($service.ContainsKey('ports')) {
            if ($name -ne 'api' -or @($service.ports).Count -ne 1 -or $service.ports[0].host_ip -ne '127.0.0.1' -or [int]$service.ports[0].published -ne $Context.config.api_port -or $service.ports[0].target -ne 8080) { throw 'Unexpected published port.' }
        } elseif ($name -eq 'api') { throw 'Missing isolated API port.' }
        if ($service.ContainsKey('volumes')) {
            foreach ($mount in $service.volumes) {
                if ($mount.type -eq 'bind') {
                    $source = [IO.Path]::GetFullPath($mount.source)
                    $readOnly = $mount.ContainsKey('read_only') -and $mount.read_only
                    $valid = ($source -eq $Context.data_dir -and $mount.target -eq '/app/data' -and ($name -ne 'worker' -or $readOnly)) -or
                        ($source -eq (Resolve-BenchPath 'data/raw') -and $mount.target -eq '/app/data/raw' -and $readOnly) -or
                        ($source -eq (Resolve-BenchPath 'tests/testdata') -and $mount.target -eq '/app/tests/testdata' -and $readOnly) -or
                        ($name -eq 'dev' -and $source -eq (Get-BenchRoot) -and $mount.target -eq '/workspace' -and $readOnly)
                    if (-not $valid) { throw "Unsafe bind mount in $name" }
                    [void](Resolve-BenchPath $source -AllowRoot)
                } elseif ($mount.type -ne 'volume' -or -not $compose.volumes.ContainsKey($mount.source)) { throw 'Unexpected volume mount.' }
            }
        }
        $limits[$name] = @{ cpus = $service.cpus; memory_bytes = $service.mem_limit; gomaxprocs = $(if ($service.ContainsKey('environment') -and $service.environment.ContainsKey('GOMAXPROCS')) { $service.environment.GOMAXPROCS } else { $null }) }
    }
    foreach ($collection in @('volumes', 'networks')) {
        foreach ($item in $compose[$collection].Values) {
            if (-not $item.name.StartsWith($Context.project + '_') -or ($item.ContainsKey('external') -and $item.external)) { throw "Unsafe $collection namespace." }
            if ($item.labels['g7.benchmark.managed'] -ne 'benchmark-v1' -or $item.labels['g7.benchmark.campaign'] -ne $Context.campaign_id) { throw "Invalid $collection labels." }
        }
    }
    return @{ limits = $limits; volumes = @($compose.volumes.Values | ForEach-Object { $_.name }); networks = @($compose.networks.Values | ForEach-Object { $_.name }) }
}

function Assert-BenchExistingResources($Context, $Resolved) {
    $ids = Invoke-BenchProcess 'docker' @('ps', '-aq', '--filter', "label=com.docker.compose.project=$($Context.project)") 20
    Assert-BenchSuccess $ids 'Existing container inventory'
    foreach ($id in @($ids.stdout -split '\r?\n' | Where-Object { $_ })) {
        $label = Invoke-BenchProcess 'docker' @('inspect', '--format', '{{index .Config.Labels "g7.benchmark.managed"}}|{{index .Config.Labels "g7.benchmark.campaign"}}', $id) 20
        Assert-BenchSuccess $label 'Container ownership'
        if ($label.stdout.Trim() -ne "benchmark-v1|$($Context.campaign_id)") { throw 'Refusing to operate on a container without benchmark ownership.' }
    }
    foreach ($kind in @('volume', 'network')) {
        $names = if ($kind -eq 'volume') { $Resolved.volumes } else { $Resolved.networks }
        foreach ($name in $names) {
            $probe = Invoke-BenchProcess 'docker' @($kind, 'inspect', '--format', '{{index .Labels "g7.benchmark.managed"}}|{{index .Labels "g7.benchmark.campaign"}}', $name) 20
            if ($probe.exit_code -ne 0) {
                # Only absence is harmless. A daemon/permission error must not be accepted.
                if ($probe.stderr -notmatch '(?i)(no such|not found)') { Assert-BenchSuccess $probe "$kind ownership" }
            } elseif ($probe.stdout.Trim() -ne "benchmark-v1|$($Context.campaign_id)") { throw "Refusing to adopt foreign $kind $name" }
        }
    }
}

function Get-BenchDemoState {
    $state = [ordered]@{ mongo_status = 'unavailable'; mongo = $null; file_hashes = [ordered]@{} }
    foreach ($directory in @('data/raw', 'data/models', 'data/processed')) {
        $full = Resolve-BenchPath $directory
        if (Test-Path -LiteralPath $full) {
            foreach ($file in @(Get-ChildItem -LiteralPath $full -File -Recurse | Sort-Object FullName)) {
                $safe = Resolve-BenchPath $file.FullName
                $relative = [IO.Path]::GetRelativePath((Get-BenchRoot), $safe).Replace('\', '/')
                $state.file_hashes[$relative] = (Get-FileHash -LiteralPath $safe).Hash.ToLowerInvariant()
            }
        }
    }
    $probe = Invoke-BenchProcess 'docker' @('ps', '-q', '--filter', 'label=com.docker.compose.project=transporte-g7', '--filter', 'label=com.docker.compose.service=mongo') 20
    Assert-BenchSuccess $probe 'Demo inventory'
    $ids = @($probe.stdout -split '\r?\n' | Where-Object { $_ })
    if ($ids.Count -eq 1) {
        $database = 'transporte'
        $demoEnv = Resolve-BenchPath '.env'
        if (Test-Path -LiteralPath $demoEnv) {
            foreach ($line in [IO.File]::ReadAllLines($demoEnv)) { if ($line -match '^MONGO_DATABASE=([a-zA-Z0-9_-]+)$') { $database = $Matches[1] } }
        }
        $js = 'const d=db.getSiblingDB("' + $database + '"); const c=d.settings.findOne({_id:"current_dataset"}); const m=c?d.datasets.findOne({_id:c.dataset_id}):null; const v=d.settings.findOne({_id:"current_model"}); print(JSON.stringify({dataset_id:c?c.dataset_id:null,load_id:m?m.load_id:null,model_version:v?v.version:null,trips:m?d.trips.countDocuments({load_id:m.load_id}):0,windows:m?d.windows.countDocuments({load_id:m.load_id}):0}));'
        $query = Invoke-BenchProcess 'docker' @('exec', $ids[0], 'mongosh', '--quiet', '--eval', $js) 30
        Assert-BenchSuccess $query 'Read-only demo snapshot'
        $state.mongo = $query.stdout | ConvertFrom-Json -AsHashtable
        $state.mongo_status = 'observed'
    }
    return $state
}

function Prepare-BenchEnvironment($Context) {
    if ($Context.scope -ne 'real') { throw 'Prepare/Smoke require the real configuration; synthetic adapters run offline only.' }
    $resolved = Assert-BenchCompose $Context
    $probe = Invoke-BenchProcess 'docker' @('info', '--format', '{{json .}}') 30
    Assert-BenchSuccess $probe 'Docker engine'
    $info = $probe.stdout | ConvertFrom-Json -AsHashtable
    if ($info.OSType -ne 'linux') { throw 'A Linux Docker engine is required.' }
    Assert-BenchExistingResources $Context $resolved
    $version = Invoke-BenchProcess 'docker' @('compose', 'version', '--short') 20
    Assert-BenchSuccess $version 'Compose version'
    $runtime = @{
        os = $info.OSType; architecture = $info.Architecture; cpus = $info.NCPU; memory_bytes = $info.MemTotal
        docker = $info.ServerVersion; compose = $version.stdout.Trim(); limits = $resolved.limits
        free_disk_bytes = ([IO.DriveInfo]::new([IO.Path]::GetPathRoot((Get-BenchRoot)))).AvailableFreeSpace
        other_running_container_count = 0; images = @(); go = $null; inputs = [ordered]@{}
    }
    $others = Invoke-BenchProcess 'docker' @('ps', '--format', '{{.Names}}', '--filter', "label=com.docker.compose.project!=$($Context.project)") 20
    Assert-BenchSuccess $others 'Other workload inventory'
    $runtime.other_running_container_count = @($others.stdout -split '\r?\n' | Where-Object { $_ }).Count
    $loaderInput = Read-BenchJson $Context.config.inputs.loader
    foreach ($pair in @(@('input', 'sha256_file'), @('zone_catalog', 'zone_sha256_file'))) {
        $path = Resolve-BenchPath $loaderInput[$pair[0]]
        $hash = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        $checksum = (Get-Content -LiteralPath (Resolve-BenchPath $loaderInput[$pair[1]]) -Raw).Trim()
        if ($hash -cne $checksum) { throw "Input checksum mismatch: $($pair[0])" }
        $runtime.inputs[$pair[0]] = @{ path = $loaderInput[$pair[0]]; sha256 = $hash; bytes = (Get-Item -LiteralPath $path).Length }
    }
    $go = Invoke-BenchProcess 'docker' @('run', '--rm', '--network', 'none', '--cpus', '1', '--memory', '256m', 'golang:1.27.2-bookworm', 'go', 'version') 120
    Assert-BenchSuccess $go 'Go toolchain version'
    $runtime.go = $go.stdout.Trim()
    Write-BenchJson (Join-Path $Context.results_dir 'environment.json') $runtime
    $loader = Read-BenchJson $Context.config.inputs.loader
    $loader.storage = 'mongo'; $loader.output = 'data/processed'; $loader.mongo_database = $Context.database
    Write-BenchJson (Join-Path $Context.data_dir 'configs/loader.json') $loader
    Write-BenchJson (Join-Path $Context.data_dir 'configs/training.json') (Read-BenchJson $Context.config.inputs.training)
    $build = Invoke-BenchCompose $Context @('--profile', 'jobs', 'build', 'loader', 'trainer', 'master', 'worker', 'api') 'prepare-build'
    Assert-BenchSuccess $build 'Benchmark build'
    $up = Invoke-BenchCompose $Context @('up', '-d', '--no-build', '--pull', 'never', '--scale', "worker=$($Context.config.initial_workers)", '--wait', '--wait-timeout', '120', 'mongo', 'redis', 'master', 'worker', 'api') 'prepare-up' 180
    Assert-BenchSuccess $up 'Benchmark startup'
    $images = Invoke-BenchCompose $Context @('--profile', '*', 'images', '--format', 'json')
    Assert-BenchSuccess $images 'Image identities'
    $runtime.images = $images.stdout | ConvertFrom-Json -AsHashtable
    Write-BenchJson (Join-Path $Context.results_dir 'environment.json') $runtime
    $manifest = Read-BenchJson (Join-Path $Context.results_dir 'manifest.json')
    $manifest.state = 'prepared'; $manifest.prepared_at = [datetime]::UtcNow.ToString('o')
    Write-BenchJson (Join-Path $Context.results_dir 'manifest.json') $manifest
}

function Assert-BenchSample($Context, $Plan, [string]$Path) {
    $full = Resolve-BenchPath $Path $Context.results_dir
    $raw = Get-Content -LiteralPath $full -Raw -Encoding utf8
    if (-not (Test-Json -Json $raw -SchemaFile $Context.result_schema -ErrorAction Stop)) { throw 'Invalid result schema.' }
    $result = $raw | ConvertFrom-Json -AsHashtable
    foreach ($key in @('campaign_id', 'sample_id', 'case_id', 'kind', 'repetition', 'warmup')) {
        if ($result[$key] -cne $Plan[$key]) { throw "Result identity mismatch: $key" }
    }
    if ($result.scope -ne $Context.scope) { throw 'Synthetic/real scope mismatch.' }
    if ($result.status -ne 'passed' -or @($result.errors).Count -gt 0) { throw 'Component reported a failed sample.' }
    if ([datetimeoffset]::Parse([string]$result.completed_at) -lt [datetimeoffset]::Parse([string]$result.started_at)) { throw 'Invalid sample timestamps.' }
    foreach ($check in $result.checks.Values) { if ($check -ne $true) { throw 'A sample validity check failed.' } }
    if ($Context.scope -eq 'real') {
        if ($result.resources.status -ne 'available' -or $result.resources.valid_samples -lt 1 -or -not $result.resources.path -or -not $result.resources.sha256) { throw 'Real samples require resource evidence.' }
        if ([IO.Path]::IsPathRooted($result.resources.path)) { throw 'Resource evidence paths must be repo-relative.' }
        $resourcePath = Resolve-BenchPath (Resolve-BenchPath $result.resources.path) $Context.raw_dir
        if ((Get-FileHash -LiteralPath $resourcePath).Hash.ToLowerInvariant() -ne $result.resources.sha256) { throw 'Resource evidence checksum mismatch.' }
        $valid = 0; $missing = 0
        foreach ($line in [IO.File]::ReadLines($resourcePath)) {
            if (-not (Test-Json -Json $line -SchemaFile (Resolve-BenchPath 'schemas/benchmark-resource.schema.json') -ErrorAction Stop)) { throw 'Invalid resource observation.' }
            $observation = $line | ConvertFrom-Json -AsHashtable
            if ($observation.sample_id -ne $Plan.sample_id) { throw 'Resources belong to another sample.' }
            if ($observation.available) { $valid++ } else { $missing++ }
        }
        if ($valid -ne $result.resources.valid_samples -or $missing -ne $result.resources.missing_samples) { throw 'Resource coverage does not match its evidence.' }
    } elseif ($result.resources.status -ne 'synthetic') { throw 'Fixture resources must be explicitly synthetic.' }
    $metrics = $result.metrics
    switch ($Plan.kind) {
        'load' {
            foreach ($key in @('reused', 'read', 'accepted', 'rejected', 'outside_period', 'persisted')) { if (-not $metrics.ContainsKey($key)) { throw "Missing load metric $key" } }
            if ($metrics.reused -ne $false -or $metrics.read -ne ($metrics.accepted + $metrics.rejected + $metrics.outside_period) -or $metrics.persisted -ne $metrics.accepted -or $metrics.accepted -lt 1) { throw 'Invalid/reused load or inconsistent counts.' }
            if ($Context.scope -eq 'real' -and $metrics.accepted -le 1000000) { throw 'Real dataset must exceed one million accepted trips.' }
            if (-not $result.checks.ContainsKey('snapshot_equivalent') -or -not $result.checks.snapshot_equivalent) { throw 'Missing snapshot equivalence check.' }
        }
        'training' {
            foreach ($key in @('workers', 'tasks_by_worker', 'candidate_max_difference', 'model_version')) { if (-not $metrics.ContainsKey($key)) { throw "Missing training metric $key" } }
            if (-not $result.checks.ContainsKey('candidate_equivalent') -or -not $result.checks.candidate_equivalent) { throw 'Missing pre-selection SGD equivalence.' }
            $expected = if ($Plan.parameters.mode -eq 'sequential') { 0 } else { $Plan.parameters.workers }
            if (@($metrics.workers).Count -ne $expected -or @($metrics.workers | Select-Object -Unique).Count -ne $expected -or $metrics.tasks_by_worker.Count -ne $expected) { throw 'Incorrect worker contribution count.' }
            foreach ($worker in $metrics.workers) { if (-not $metrics.tasks_by_worker.ContainsKey($worker) -or $metrics.tasks_by_worker[$worker] -lt 1) { throw 'Worker did not contribute.' } }
            if ($Context.scope -eq 'real') {
                foreach ($key in @('candidate_diagnostics_path', 'candidate_diagnostics_sha256')) { if (-not $metrics.ContainsKey($key)) { throw "Missing pre-selection candidate evidence: $key" } }
                if ([IO.Path]::IsPathRooted($metrics.candidate_diagnostics_path)) { throw 'Candidate diagnostic paths must be repo-relative.' }
                $diagnosticsPath = Resolve-BenchPath (Resolve-BenchPath $metrics.candidate_diagnostics_path) $Context.raw_dir
                if ((Get-FileHash -LiteralPath $diagnosticsPath).Hash.ToLowerInvariant() -ne $metrics.candidate_diagnostics_sha256) { throw 'Candidate diagnostics checksum mismatch.' }
                $diagnostics = Read-BenchJson $diagnosticsPath
                if ($diagnostics.sample_id -ne $Plan.sample_id -or @($diagnostics.candidate_weights).Count -eq 0 -or @($diagnostics.candidate_weights).Count -ne @($diagnostics.reference_weights).Count) { throw 'Invalid candidate diagnostic identity/dimensions.' }
                $difference = 0.0
                for ($i = 0; $i -lt $diagnostics.candidate_weights.Count; $i++) {
                    $a = [double]$diagnostics.reference_weights[$i]; $b = [double]$diagnostics.candidate_weights[$i]
                    if (-not [double]::IsFinite($a) -or -not [double]::IsFinite($b)) { throw 'Non-finite candidate weights.' }
                    $delta = [Math]::Abs($a - $b)
                    $limit = $Context.config.protocol.absolute_tolerance + $Context.config.protocol.relative_tolerance * [Math]::Max([Math]::Abs($a), [Math]::Abs($b))
                    if ($delta -gt $limit) { throw 'Candidate SGD equivalence failed before selection.' }
                    $difference = [Math]::Max($difference, $delta)
                }
                if ([Math]::Abs($difference - $metrics.candidate_max_difference) -gt 1e-15) { throw 'Candidate maximum difference does not match evidence.' }
            }
        }
        'api' {
            foreach ($key in @('attempted', 'completed', 'errors', 'cache_hits', 'p50_ms', 'p95_ms', 'p99_ms', 'max_ms', 'objective_met')) { if (-not $metrics.ContainsKey($key)) { throw "Missing API metric $key" } }
            if ($metrics.attempted -ne $Plan.parameters.requests -or $metrics.completed -ne $metrics.attempted -or $metrics.errors -ne 0) { throw 'Incomplete API attempts or unexpected errors.' }
            $hits = if ($Plan.parameters.cache -eq 'warm') { $metrics.completed } else { 0 }
            if ($metrics.cache_hits -ne $hits) { throw 'Unexpected API cache behavior.' }
            $previous = 0.0
            foreach ($key in @('p50_ms', 'p95_ms', 'p99_ms', 'max_ms')) {
                $value = [double]$metrics[$key]
                if (-not [double]::IsFinite($value) -or $value -lt $previous) { throw 'Invalid API percentile ordering.' }
                $previous = $value
            }
            if ($metrics.objective_met -ne ($metrics.p95_ms -lt $Context.config.protocol.api_p95_objective_ms)) { throw 'Incorrect API objective declaration.' }
        }
    }
    return $result
}

function Invoke-BenchCampaign($Context) {
    Assert-BenchOwnership $Context
    $manifestPath = Join-Path $Context.results_dir 'manifest.json'
    $manifest = Read-BenchJson $manifestPath
    if ($manifest.ContainsKey('run_started_at')) { throw 'A run cannot be overwritten/retried in the same campaign.' }
    if (Test-Path -LiteralPath (Join-Path $Context.results_dir 'smoke.json')) { throw 'Use a new campaign for real measurements; this campaign contains a synthetic infrastructure smoke.' }
    $missing = @(Get-BenchMissingComponents $Context.config)
    $manifest.missing_components = $missing
    if ($missing.Count -gt 0) {
        $manifest.state = 'blocked'; $manifest.errors = @('Missing component adapters: ' + ($missing -join ', '))
        Write-BenchJson $manifestPath $manifest
        throw $manifest.errors[0]
    }
    if ($Context.scope -eq 'real') {
        if (-not $manifest.ContainsKey('prepared_at')) { throw 'Prepare the isolated environment before running real samples.' }
        $resolved = Assert-BenchCompose $Context
        Assert-BenchExistingResources $Context $resolved
        $health = Invoke-BenchCompose $Context @('ps', '--format', 'json')
        Assert-BenchSuccess $health 'Pre-run health'
        $services = @($health.stdout | ConvertFrom-Json -AsHashtable)
        foreach ($name in @('mongo', 'redis', 'master', 'api')) {
            $matches = @($services | Where-Object { $_.Service -eq $name -and $_.State -eq 'running' -and $_.Health -eq 'healthy' })
            if ($matches.Count -ne 1) { throw "Service is not healthy: $name" }
        }
    }
    $manifest.state = 'running'; $manifest.errors = @(); $manifest.run_started_at = [datetime]::UtcNow.ToString('o')
    Write-BenchJson $manifestPath $manifest
    $dataset = $null
    try {
        foreach ($sample in @(Read-BenchJson (Join-Path $Context.results_dir 'plan.json'))) {
            $sampleInput = Join-Path $Context.raw_dir "plans/$($sample.sample_id).json"
            $sampleOutput = Join-Path $Context.results_dir "samples/$($sample.sample_id).json"
            Write-BenchJson $sampleInput $sample
            $record = @{ sample_id = $sample.sample_id; state = 'running'; warmup = $sample.warmup }
            $manifest.samples += $record
            Write-BenchJson $manifestPath $manifest
            try {
                $script = Resolve-BenchPath $Context.config.components[$sample.kind]
                $call = Invoke-BenchProcess (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) @('-NoProfile', '-File', $script, '-ContextPath', $Context.context_path, '-SamplePath', $sampleInput, '-OutputPath', $sampleOutput) $Context.config.timeout_seconds (Join-Path $Context.raw_dir "logs/$($sample.sample_id)")
                Assert-BenchSuccess $call "Adapter $($sample.kind)/$($sample.sample_id)"
                $result = Assert-BenchSample $Context $sample $sampleOutput
                if ($null -eq $dataset) { $dataset = $result.dataset }
                foreach ($key in @('id', 'snapshot_sha256', 'source_sha256', 'catalog_sha256')) {
                    if ($result.dataset[$key] -ne $dataset[$key]) { throw "Dataset changed between cases: $key" }
                }
                $record.state = 'passed'; $record.result = [IO.Path]::GetRelativePath((Get-BenchRoot), $sampleOutput).Replace('\', '/')
                $record.adapter_elapsed_seconds = $call.elapsed_seconds
            } catch {
                $record.state = 'failed'; $record.error = Protect-BenchText $_.Exception.Message
                throw
            } finally { Write-BenchJson $manifestPath $manifest }
        }
        $summaryPath = Join-Path $Context.results_dir 'summary.json'
        $call = Invoke-BenchProcess (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) @('-NoProfile', '-File', (Resolve-BenchPath $Context.config.components.summary), '-ContextPath', $Context.context_path, '-ManifestPath', $manifestPath, '-OutputPath', $summaryPath) $Context.config.timeout_seconds (Join-Path $Context.raw_dir 'logs/summary')
        Assert-BenchSuccess $call 'Summary adapter'
        $summary = Read-BenchJson $summaryPath
        if ($summary.schema_version -ne 'benchmark-v1' -or $summary.campaign_id -ne $Context.campaign_id -or $summary.scope -ne $Context.scope -or $summary.status -ne 'passed') { throw 'Invalid summary identity/status.' }
        if ((@($summary.sample_ids | Sort-Object) | ConvertTo-Json -Compress) -ne (@($manifest.samples.sample_id | Sort-Object) | ConvertTo-Json -Compress)) { throw 'Summary omitted or duplicated samples.' }
        $manifest.state = if ($Context.scope -eq 'real') { 'completed' } else { 'fixture_passed' }
        $manifest.objective_evaluated = $Context.scope -eq 'real'
    } catch {
        $manifest.state = 'failed'; $manifest.errors += (Protect-BenchText $_.Exception.Message)
        throw
    } finally {
        $manifest.completed_at = [datetime]::UtcNow.ToString('o')
        Write-BenchJson $manifestPath $manifest
    }
}

function Invoke-BenchSmoke($Context) {
    $evidencePath = Join-Path $Context.results_dir 'smoke.json'
    if (Test-Path -LiteralPath $evidencePath) { throw 'Smoke evidence already exists. Use a new campaign.' }
    Prepare-BenchEnvironment $Context
    $fixture = Read-BenchJson 'configs/fixture.json'
    $fixture.storage = 'mongo'; $fixture.output = 'data/processed'; $fixture.mongo_database = $Context.database
    Write-BenchJson (Join-Path $Context.data_dir 'configs/smoke-loader.json') $fixture
    $training = @{ epochs = 3; batch_size = 16; learning_rate = 0.04; l2 = 0.0001; seed = 42; workers = $Context.config.initial_workers; task_timeout_seconds = 10 }
    Write-BenchJson (Join-Path $Context.data_dir 'configs/smoke-training.json') $training
    $load = Invoke-BenchCompose $Context @('--profile', 'jobs', 'run', '--rm', '--no-deps', 'loader', '-config', 'data/configs/smoke-loader.json') 'smoke-loader' 120
    Assert-BenchSuccess $load 'Fixture load'
    $loaded = $load.stdout | ConvertFrom-Json -AsHashtable
    if ($loaded.reused -ne $false -or $loaded.manifest.stats.accepted -ne 3 -or $loaded.manifest.snapshot.windows -ne 192) { throw 'Unexpected fixture dataset/reused load.' }
    Write-BenchJson (Join-Path $Context.results_dir 'smoke/loader.json') $loaded
    $secrets = Get-BenchSecrets $Context
    $token = $null
    $headers = @{}
    try {
        $login = Invoke-RestMethod ($Context.api_url + '/api/v1/auth/login') -Method Post -ContentType application/json -Body (@{ username = 'benchmark'; password = $secrets.BENCH_PASSWORD } | ConvertTo-Json) -TimeoutSec 10
        $token = $login.access_token; $script:BenchSecrets += $token; $headers = @{ Authorization = "Bearer $token" }
        $deadline = [datetime]::UtcNow.AddSeconds(45)
        do {
            $cluster = Invoke-RestMethod ($Context.api_url + '/api/v1/cluster') -Headers $headers -TimeoutSec 5
            if (@($cluster.workers).Count -eq $Context.config.initial_workers) { break }
            Start-Sleep -Milliseconds 500
        } while ([datetime]::UtcNow -lt $deadline)
        if (@($cluster.workers).Count -ne $Context.config.initial_workers) { throw 'Incorrect number of connected smoke workers.' }
        $runs = @{}
        foreach ($mode in @('sequential', 'distributed')) {
            $train = Invoke-BenchCompose $Context @('--profile', 'jobs', 'run', '--rm', '--no-deps', 'trainer', '-mode', $mode, '-config', 'data/configs/smoke-training.json') "smoke-$mode" 120
            Assert-BenchSuccess $train "Fixture training $mode"
            $runs[$mode] = $train.stdout | ConvertFrom-Json -AsHashtable
            if ($runs[$mode].run.status -ne 'completed' -or $runs[$mode].artifact.dataset_id -ne $loaded.manifest.dataset_id) { throw 'Smoke run did not complete on the fixture dataset.' }
            Write-BenchJson (Join-Path $Context.results_dir "smoke/$mode.json") $runs[$mode]
        }
        if (@($runs.distributed.run.workers).Count -ne $Context.config.initial_workers) { throw 'Distributed smoke workers missing.' }
        foreach ($worker in $runs.distributed.run.workers) { if ($runs.distributed.run.tasks_by_worker[$worker] -lt 1) { throw 'Smoke worker did not contribute.' } }
        $deadline = [datetime]::UtcNow.AddSeconds(45)
        do {
            $model = Invoke-RestMethod ($Context.api_url + '/api/v1/models/current') -Headers $headers -TimeoutSec 5
            if ($model.ready -and $model.version -eq $runs.distributed.artifact.version) { break }
            Start-Sleep -Milliseconds 500
        } while ([datetime]::UtcNow -lt $deadline)
        if (-not $model.ready -or $model.version -ne $runs.distributed.artifact.version) { throw 'API did not load the fixture model.' }
        $body = @{ dataset_id = $loaded.manifest.dataset_id; zone_id = $loaded.manifest.zones[0].id; forecast_origin = $model.first_origin; horizon_minutes = 15 } | ConvertTo-Json
        $first = Invoke-RestMethod ($Context.api_url + '/api/v1/predictions') -Method Post -Headers $headers -ContentType application/json -Body $body -TimeoutSec 10
        $second = Invoke-RestMethod ($Context.api_url + '/api/v1/predictions') -Method Post -Headers $headers -ContentType application/json -Body $body -TimeoutSec 10
        if ($first.cache_hit -or -not $second.cache_hit -or $second.model_version -ne $model.version) { throw 'Smoke prediction/cache check failed.' }
        $query = Invoke-BenchCompose $Context @('exec', '-T', 'mongo', 'mongosh', '--quiet', '--eval', 'const d=db.getSiblingDB("g7_benchmark"); print(JSON.stringify({trips:d.trips.countDocuments({}),windows:d.windows.countDocuments({})}));') 'smoke-counts' 30
        Assert-BenchSuccess $query 'Independent fixture MongoDB counts'
        $counts = $query.stdout | ConvertFrom-Json -AsHashtable
        if ($counts.trips -ne 3 -or $counts.windows -ne 192) { throw 'MongoDB fixture counts disagree.' }
        Write-BenchJson $evidencePath @{
            schema_version = 'benchmark-v1'; campaign_id = $Context.campaign_id
            scope = 'infrastructure_smoke_synthetic_data'; status = 'passed'; created_at = [datetime]::UtcNow.ToString('o')
            counts = $counts; workers = $runs.distributed.run.workers; tasks_by_worker = $runs.distributed.run.tasks_by_worker
            dataset_id = $loaded.manifest.dataset_id; model_version = $model.version
            cache_miss_then_hit = $true; candidate_equivalence_verified = $false
            pending = @('Real component adapters #2/#4/#5', 'Pre-selection SGD diagnostics #3', 'Formal resource measurements #4', 'Real repeated campaigns', 'Final audit by Vera')
        }
        $manifestPath = Join-Path $Context.results_dir 'manifest.json'
        $manifest = Read-BenchJson $manifestPath; $manifest.state = 'smoke_passed'; $manifest.objective_evaluated = $false
        Write-BenchJson $manifestPath $manifest
    } finally {
        if ($token) { Invoke-RestMethod ($Context.api_url + '/api/v1/auth/logout') -Method Post -Headers $headers -ContentType application/json -Body '{}' -TimeoutSec 5 | Out-Null }
    }
}

function Export-BenchEvidence($Context) {
    [void](Get-BenchSecrets $Context)
    $destination = Resolve-BenchPath ".cache/benchmark/exports/$($Context.campaign_id).zip"
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($directory in @($Context.results_dir, $Context.raw_dir)) {
            foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse) {
                $full = Resolve-BenchPath $file.FullName $directory
                if ($file.Extension -notin @('.json', '.ndjson', '.csv', '.txt', '.log', '.patch')) { continue }
                $entry = $zip.CreateEntry([IO.Path]::GetRelativePath((Get-BenchRoot), $full).Replace('\', '/'))
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write((Protect-BenchText ([IO.File]::ReadAllText($full)))) } finally { $writer.Dispose() }
            }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
    return $destination
}

Export-ModuleMember -Function *-Bench*
