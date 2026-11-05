#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-BenchMemory([string]$Text) {
    if ($Text -notmatch '^\s*(\d+(?:\.\d+)?)\s*(B|kB|KB|MB|GB|TB|KiB|MiB|GiB|TiB)\s*$') { throw 'Invalid Docker memory quantity.' }
    $units = @{ B = 1; KB = 1000; MB = 1000000; GB = 1000000000; TB = 1000000000000; KiB = 1024; MiB = 1048576; GiB = 1073741824; TiB = 1099511627776 }
    $bytes = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) * $units[$Matches[2]]
    if (-not [double]::IsFinite($bytes) -or $bytes -gt [long]::MaxValue) { throw 'Memory overflow.' }
    return [long][Math]::Round($bytes)
}

function ConvertFrom-BenchProc([string]$Text) {
    $lines = @($Text -split '\r?\n')
    if ($lines.Count -lt 3 -or $lines[0] -notmatch '^\d+$' -or [double]$lines[0] -le 0 -or
        $lines[1] -notmatch '^1 \(.*\) (.+)$') { throw 'Invalid /proc counter snapshot.' }
    $fields = $Matches[1] -split '\s+'
    if ($fields.Count -lt 20) { throw 'Truncated /proc/1/stat.' }
    foreach ($i in @(11, 12, 19)) { if ($fields[$i] -notmatch '^\d+$') { throw 'Invalid process CPU/start counter.' } }
    $rss = @($lines | Where-Object { $_ -match '^VmRSS:\s+(\d+)\s+kB\s*$' })
    if ($rss.Count -ne 1 -or $rss[0] -notmatch '^VmRSS:\s+(\d+)\s+kB\s*$') { throw 'Process RSS unavailable.' }
    return @{
        cpu_seconds = ([double]$fields[11] + [double]$fields[12]) / [double]$lines[0]
        start_ticks = $fields[19]; memory_bytes = [long]$Matches[1] * 1024
    }
}

function New-BenchObservation([string]$SampleId, [string]$Service, [string]$Scope, [datetimeoffset]$At, $CPU = $null, $Memory = $null) {
    $available = $null -ne $CPU -and $null -ne $Memory
    return [ordered]@{
        schema_version = 'benchmark-v1'; sample_id = $SampleId; sampled_at = $At.ToUniversalTime().ToString('o')
        service = $Service; scope = $Scope; available = $available
        cpu_percent = $(if ($available) { $CPU } else { $null }); memory_bytes = $(if ($available) { $Memory } else { $null })
    }
}

function Get-BenchProcessObservation {
    param([string]$Text, $Previous, [datetimeoffset]$At, [string]$SampleId, [string]$Service)
    $counters = ConvertFrom-BenchProc $Text
    $cpu = $null
    if ($null -ne $Previous -and $Previous.start_ticks -eq $counters.start_ticks) {
        $elapsed = ($At - [datetimeoffset]$Previous.at).TotalSeconds
        $delta = $counters.cpu_seconds - $Previous.cpu_seconds
        if ($elapsed -gt 0 -and $delta -ge 0) { $cpu = 100 * $delta / $elapsed }
    }
    $counters.at = $At
    return @{
        counters = $counters
        observation = (New-BenchObservation $SampleId $Service 'process' $At $cpu $counters.memory_bytes)
    }
}

function Get-BenchResourceSnapshot {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$SampleId,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.IDictionary]$Previous,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.IDictionary]$Known,
        [Parameter(Mandatory)][scriptblock]$Docker
    )
    $observations = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $list = & $Docker @('ps', '--all', '--no-trunc', '--filter', "label=com.docker.compose.project=$($Context.project)", '--filter', 'label=g7.benchmark.managed=benchmark-v1', '--filter', "label=g7.benchmark.campaign=$($Context.campaign_id)", '--format', '{{.ID}}')
    if ($list.exit_code -ne 0) { throw 'Could not discover benchmark containers.' }
    $ids = @($list.stdout -split '\r?\n' | Where-Object { $_ })
    $running = [Collections.Generic.List[string]]::new()
    foreach ($id in $ids) {
        if ($id -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid container ID from Docker.' }
        $inspect = & $Docker @('inspect', '--format', '{"labels":{{json .Config.Labels}},"running":{{json .State.Running}}}', $id)
        if ($inspect.exit_code -ne 0) { $errors.Add("Container disappeared before inspection: $id"); continue }
        $info = $inspect.stdout | ConvertFrom-Json -AsHashtable
        foreach ($entry in @{
            'com.docker.compose.project' = $Context.project
            'g7.benchmark.managed' = 'benchmark-v1'
            'g7.benchmark.campaign' = $Context.campaign_id
        }.GetEnumerator()) {
            if ($info.labels[$entry.Key] -cne $entry.Value) { throw 'Refusing to inspect a container outside this benchmark campaign.' }
        }
        $role = [string]$info.labels['com.docker.compose.service']
        if ($role -notin @('mongo', 'redis', 'master', 'worker', 'api', 'loader', 'trainer')) { continue }
        $service = "$role/$id"
        $Known[$id] = @{ service = $service; process = $role -in @('master', 'worker', 'api', 'loader', 'trainer') }
        if (-not $info.running) { continue }
        $running.Add($id)
    }
    $statsById = @{}
    if ($running.Count) {
        $stats = & $Docker (@('stats', '--no-stream', '--no-trunc', '--format', '{{json .}}') + $running.ToArray())
        $statsAt = [datetimeoffset]::UtcNow
        if ($stats.exit_code -eq 0) {
            foreach ($line in @($stats.stdout -split '\r?\n' | Where-Object { $_ })) {
                try {
                    $row = $line | ConvertFrom-Json -AsHashtable
                    if ($row.ID -notin $running) { throw 'Unexpected stats container identity.' }
                    if ($statsById.ContainsKey($row.ID)) { throw 'Duplicate stats identity.' }
                    $statsById[$row.ID] = $row
                } catch { $errors.Add('Invalid container stats record.') }
            }
        } else { $errors.Add('Container stats batch unavailable.') }
    }
    foreach ($id in $running) {
        $service = $Known[$id].service
        $cpu = $null; $memory = $null
        try {
            if (-not $statsById.ContainsKey($id)) { throw 'Container stats unavailable.' }
            $row = $statsById[$id]
            if ($row.CPUPerc -notmatch '^(\d+(?:\.\d+)?)%$') { throw 'Invalid container CPU.' }
            $cpu = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
            $memory = ConvertFrom-BenchMemory (($row.MemUsage -split '/')[0].Trim())
        } catch { $cpu = $null; $memory = $null; $errors.Add("Container stats unavailable: $id") }
        $observations.Add((New-BenchObservation $SampleId $service 'container' $statsAt $cpu $memory))
        if ($Known[$id].process) {
            try {
                $proc = & $Docker @('exec', $id, 'sh', '-c', 'getconf CLK_TCK && cat /proc/1/stat /proc/1/status')
                if ($proc.exit_code -ne 0) { throw 'Process counters unavailable.' }
                $result = Get-BenchProcessObservation $proc.stdout $Previous[$id] ([datetimeoffset]::UtcNow) $SampleId $service
                $Previous[$id] = $result.counters
                $observations.Add($result.observation)
            } catch {
                $Previous.Remove($id)
                $errors.Add("Process counters unavailable: $id")
                $observations.Add((New-BenchObservation $SampleId $service 'process' ([datetimeoffset]::UtcNow)))
            }
        }
    }
    # Include explicit missing observations for exited/removed jobs already seen.
    foreach ($id in @($Known.Keys)) {
        $service = $Known[$id].service
        if (@($observations | Where-Object service -CEQ $service).Count) { continue }
        $observations.Add((New-BenchObservation $SampleId $service 'container' ([datetimeoffset]::UtcNow)))
        if ($Known[$id].process) { $observations.Add((New-BenchObservation $SampleId $service 'process' ([datetimeoffset]::UtcNow))) }
        $Previous.Remove($id)
    }
    return @{ observations = @($observations.ToArray()); errors = @($errors.ToArray()) }
}

Export-ModuleMember -Function ConvertFrom-BenchMemory, ConvertFrom-BenchProc, New-BenchObservation, Get-BenchProcessObservation, Get-BenchResourceSnapshot
