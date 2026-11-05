#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-BenchCanonicalJson($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $pairs = foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            ($key | ConvertTo-Json -Compress) + ':' + (ConvertTo-BenchCanonicalJson $Value[$key])
        }
        return '{' + ($pairs -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = foreach ($item in $Value) { ConvertTo-BenchCanonicalJson $item }
        return '[' + ($items -join ',') + ']'
    }
    return ConvertTo-Json -InputObject $Value -Compress -Depth 30
}

function Assert-BenchNumber($Value, [switch]$Positive) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or
        $Value -isnot [ValueType] -or -not [double]::IsFinite([double]$Value) -or
        [double]$Value -lt 0 -or ($Positive -and [double]$Value -le 0)) {
        throw 'Expected a finite nonnegative number (strictly positive for a time/denominator).'
    }
}

function Get-BenchStatistics {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Values)
    if ($Values.Count -eq 0) { throw 'Cannot aggregate an empty series.' }
    foreach ($value in $Values) { Assert-BenchNumber $value }
    $sorted = @($Values | ForEach-Object { [double]$_ } | Sort-Object)
    $mean = 0.0
    $m2 = 0.0
    $count = 0
    # Welford avoids subtracting two large, nearly equal sums of squares.
    foreach ($value in $sorted) {
        $count++
        $delta = $value - $mean
        $mean += $delta / $count
        $m2 += $delta * ($value - $mean)
    }
    $middle = [int][Math]::Floor($count / 2)
    $median = if ($count % 2) { $sorted[$middle] } else { $sorted[$middle - 1] / 2 + $sorted[$middle] / 2 }
    $deviation = if ($count -gt 1) { [Math]::Sqrt($m2 / ($count - 1)) } else { $null }
    foreach ($number in @($mean, $median, $m2)) {
        if (-not [double]::IsFinite($number)) { throw 'Numeric overflow while aggregating.' }
    }
    return [ordered]@{ count = $count; mean = $mean; median = $median; min = $sorted[0]; max = $sorted[-1]; sample_stddev = $deviation }
}

function Get-BenchSpeedup {
    param($Sequential, $DistributedOne, $Distributed, [int]$Workers)
    foreach ($time in @($Sequential, $DistributedOne, $Distributed)) { Assert-BenchNumber $time -Positive }
    if ($Workers -notin @(1, 2, 4)) { throw 'Expected 1, 2 or 4 workers.' }
    $s = [double]$Sequential / [double]$Distributed
    $d = [double]$DistributedOne / [double]$Distributed
    if (-not [double]::IsFinite($s) -or -not [double]::IsFinite($d)) { throw 'Speedup overflow.' }
    return [ordered]@{ speedup_vs_sequential = $s; speedup_vs_d1 = $d; efficiency_vs_d1 = $d / $Workers }
}

function Get-BenchResourceSummary {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Observations,
        [ValidateRange(0, 10)][double]$MaxSkewSeconds = 0.25
    )
    $services = [Collections.Generic.List[object]]::new()
    $totals = [Collections.Generic.List[object]]::new()
    foreach ($scope in @('process', 'container')) {
        $rows = @($Observations | Where-Object scope -EQ $scope)
        $names = @($rows | ForEach-Object service | Sort-Object -Unique)
        $series = @{}
        foreach ($name in $names) {
            $all = @($rows | Where-Object service -CEQ $name | Sort-Object { [datetimeoffset]::Parse($_.sampled_at) })
            $valid = @($all | Where-Object available)
            foreach ($row in $valid) {
                Assert-BenchNumber $row.cpu_percent
                Assert-BenchNumber $row.memory_bytes
            }
            $cpu = if ($valid.Count) { Get-BenchStatistics @($valid.cpu_percent) } else { $null }
            $ram = if ($valid.Count) { (@($valid.memory_bytes) | Measure-Object -Maximum).Maximum } else { $null }
            $services.Add([ordered]@{
                service = $name; scope = $scope; valid_samples = $valid.Count; missing_samples = $all.Count - $valid.Count
                cpu_percent = $cpu; max_memory_bytes = $ram
                first_observed_at = $all[0].sampled_at; last_observed_at = $all[-1].sampled_at
            })
            $series[$name] = $all
        }
        # Match each observation at most once. Never sum per-service maxima or carry
        # an old sample forward. An unavailable row invalidates that aligned group.
        $alignedCPU = [Collections.Generic.List[object]]::new()
        $alignedRAM = [Collections.Generic.List[object]]::new()
        $positions = @{}
        foreach ($name in $names) { $positions[$name] = 0 }
        if ($names.Count) {
            foreach ($anchor in $series[$names[0]]) {
                $at = [datetimeoffset]::Parse($anchor.sampled_at)
                $chosen = @($anchor)
                foreach ($name in @($names | Select-Object -Skip 1)) {
                    $items = $series[$name]
                    $index = $positions[$name]
                    while ($index -lt $items.Count -and ([datetimeoffset]::Parse($items[$index].sampled_at) - $at).TotalSeconds -lt -$MaxSkewSeconds) { $index++ }
                    $positions[$name] = $index
                    if ($index -ge $items.Count) { continue }
                    if ([Math]::Abs(([datetimeoffset]::Parse($items[$index].sampled_at) - $at).TotalSeconds) -le $MaxSkewSeconds) {
                        $chosen += $items[$index]
                        $positions[$name] = $index + 1
                    }
                }
                if ($chosen.Count -ne $names.Count -or @($chosen | Where-Object { -not $_.available }).Count) { continue }
                $times = @($chosen | ForEach-Object { [datetimeoffset]::Parse($_.sampled_at).UtcTicks } | Sort-Object)
                if (($times[-1] - $times[0]) / [timespan]::TicksPerSecond -gt $MaxSkewSeconds) { continue }
                $alignedCPU.Add(($chosen.cpu_percent | Measure-Object -Sum).Sum)
                $alignedRAM.Add(($chosen.memory_bytes | Measure-Object -Sum).Sum)
            }
        }
        $totals.Add([ordered]@{
            scope = $scope; services = $names; aligned_samples = $alignedRAM.Count; max_skew_seconds = $MaxSkewSeconds
            cpu_percent = $(if ($alignedCPU.Count) { Get-BenchStatistics $alignedCPU.ToArray() } else { $null })
            max_memory_bytes = $(if ($alignedRAM.Count) { ($alignedRAM | Measure-Object -Maximum).Maximum } else { $null })
        })
    }
    return [ordered]@{ services = @($services.ToArray()); totals = @($totals.ToArray()) }
}

Export-ModuleMember -Function ConvertTo-BenchCanonicalJson, Assert-BenchNumber, Get-BenchStatistics, Get-BenchSpeedup, Get-BenchResourceSummary
