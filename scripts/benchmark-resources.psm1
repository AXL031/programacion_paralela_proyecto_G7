$ErrorActionPreference = 'Stop'

function Write-BenchmarkCaptureError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $taskEncoding = New-Object System.Text.UTF8Encoding($false)
    $taskLine = [DateTimeOffset]::UtcNow.ToString('o') + ' ' + $Message + [Environment]::NewLine
    [IO.File]::AppendAllText($Path, $taskLine, $taskEncoding)
}

function Start-BenchmarkResourceCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+$')]
        [string]$ProjectName,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [ValidateRange(1, 60)]
        [int]$IntervalSeconds = 1
    )
    $taskDocker = Get-Command docker -ErrorAction Stop
    $taskResolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    $taskOutputDirectory = Split-Path -Parent $taskResolvedOutput
    New-Item -ItemType Directory -Force -Path $taskOutputDirectory | Out-Null
    if (Test-Path -LiteralPath $taskResolvedOutput) {
        throw ('Resource capture output already exists: ' + $taskResolvedOutput)
    }
    $taskErrorPath = $taskResolvedOutput + '.errors'
    if (Test-Path -LiteralPath $taskErrorPath) {
        throw ('Resource capture error output already exists: ' + $taskErrorPath)
    }
    $taskStartedAt = [DateTimeOffset]::UtcNow
    $taskStopPath = $taskResolvedOutput + '.stop'
    $taskJob = Start-Job -ArgumentList @(
        $taskDocker.Source,
        $ProjectName,
        $taskResolvedOutput,
        $taskErrorPath,
        $taskStopPath,
        $IntervalSeconds
    ) -ScriptBlock {
        param($DockerPath, $ComposeProject, $OutputPath, $ErrorPath, $StopPath, $Interval)
        $encoding = New-Object System.Text.UTF8Encoding($false)
        try {
            while (-not (Test-Path -LiteralPath $StopPath)) {
                $containerOutput = & $DockerPath ps `
                    --filter ('label=com.docker.compose.project=' + $ComposeProject) `
                    --format '{{.ID}}' 2>&1
                $containerExitCode = $LASTEXITCODE
                if ($containerExitCode -ne 0) {
                    $message = 'docker ps failed: ' + ($containerOutput -join ' ')
                    $line = [DateTimeOffset]::UtcNow.ToString('o') + ' ' + $message + [Environment]::NewLine
                    [IO.File]::AppendAllText($ErrorPath, $line, $encoding)
                    break
                }
                $containerIDs = @($containerOutput | ForEach-Object { ([string]$_).Trim() } |
                    Where-Object { $_ -match '^[a-fA-F0-9]{12,64}$' } |
                    Sort-Object -Unique)
                if ($containerIDs.Count -gt 0) {
                    $statsArguments = @('stats', '--no-stream', '--format', '{{json .}}') + $containerIDs
                    $statsOutput = & $DockerPath @statsArguments 2>&1
                    $statsExitCode = $LASTEXITCODE
                    if ($statsExitCode -ne 0) {
                        $message = 'docker stats failed: ' + ($statsOutput -join ' ')
                        $line = [DateTimeOffset]::UtcNow.ToString('o') + ' ' + $message + [Environment]::NewLine
                        [IO.File]::AppendAllText($ErrorPath, $line, $encoding)
                        break
                    }
                    $sampleTime = [DateTimeOffset]::UtcNow.ToString('o')
                    foreach ($statsLine in $statsOutput) {
                        if ([string]::IsNullOrWhiteSpace([string]$statsLine)) {
                            continue
                        }
                        try {
                            $stats = ([string]$statsLine) | ConvertFrom-Json -ErrorAction Stop
                            $record = [ordered]@{
                                sampled_at_utc = $sampleTime
                                stats = $stats
                            }
                            [IO.File]::AppendAllText(
                                $OutputPath,
                                (($record | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine),
                                $encoding
                            )
                        } catch {
                            $message = 'Invalid docker stats JSON: ' + $_.Exception.Message
                            $line = [DateTimeOffset]::UtcNow.ToString('o') + ' ' + $message + [Environment]::NewLine
                            [IO.File]::AppendAllText($ErrorPath, $line, $encoding)
                            break
                        }
                    }
                }
                Start-Sleep -Seconds $Interval
            }
        } catch {
            $message = 'Resource sampler failed: ' + $_.Exception.Message
            $line = [DateTimeOffset]::UtcNow.ToString('o') + ' ' + $message + [Environment]::NewLine
            [IO.File]::AppendAllText($ErrorPath, $line, $encoding)
            throw
        }
    }
    Start-Sleep -Milliseconds 200
    if ($taskJob.State -eq 'Failed') {
        $taskJob | Receive-Job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Id $taskJob.Id -Force
        throw 'Docker resource sampler failed to start.'
    }
    [pscustomobject]@{
        JobId = $taskJob.Id
        ProjectName = $ProjectName
        StartedAt = $taskStartedAt
        OutputPath = $taskResolvedOutput
        ErrorPath = $taskErrorPath
        StopPath = $taskStopPath
        IntervalSeconds = $IntervalSeconds
    }
}

function ConvertFrom-DockerStatsSample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )
    $taskRecord = $Line | ConvertFrom-Json -ErrorAction Stop
    if (-not $taskRecord.stats -or -not $taskRecord.stats.Name) {
        throw 'Docker stats sample must include stats.Name.'
    }
    $taskStats = $taskRecord.stats
    $taskCpuMatch = [regex]::Match([string]$taskStats.CPUPerc, '[-+]?\d+(?:\.\d+)?')
    $taskMemoryMatch = [regex]::Match([string]$taskStats.MemUsage, '^\s*(?<used>[\d.,]+)\s*(?<used_unit>[A-Za-z]+)\s*/\s*(?<limit>[\d.,]+)\s*(?<limit_unit>[A-Za-z]+)')
    $taskMemoryPercentMatch = [regex]::Match([string]$taskStats.MemPerc, '[-+]?\d+(?:\.\d+)?')
    if (-not $taskCpuMatch.Success -or -not $taskMemoryMatch.Success -or -not $taskMemoryPercentMatch.Success) {
        throw ('Docker stats sample has an invalid CPU or memory value for container ' + $taskStats.Name)
    }
    $taskUnits = @{
        B = 1.0
        KB = 1000.0
        MB = 1000000.0
        GB = 1000000000.0
        TB = 1000000000000.0
        KiB = 1024.0
        MiB = 1048576.0
        GiB = 1073741824.0
        TiB = 1099511627776.0
    }
    $taskUsedUnit = [string]$taskMemoryMatch.Groups['used_unit'].Value
    $taskLimitUnit = [string]$taskMemoryMatch.Groups['limit_unit'].Value
    if (-not $taskUnits.ContainsKey($taskUsedUnit) -or -not $taskUnits.ContainsKey($taskLimitUnit)) {
        throw ('Docker stats sample uses an unsupported memory unit for container ' + $taskStats.Name)
    }
    $taskCulture = [Globalization.CultureInfo]::InvariantCulture
    $taskUsed = [double]::Parse($taskMemoryMatch.Groups['used'].Value, $taskCulture)
    $taskLimit = [double]::Parse($taskMemoryMatch.Groups['limit'].Value, $taskCulture)
    [pscustomobject]@{
        SampledAtUtc = [DateTimeOffset]::Parse([string]$taskRecord.sampled_at_utc, $taskCulture).ToUniversalTime()
        Container = [string]$taskStats.Name
        ContainerID = [string]$taskStats.ID
        CPUPercent = [double]::Parse($taskCpuMatch.Value, $taskCulture)
        MemoryUsageBytes = [long][Math]::Round($taskUsed * $taskUnits[$taskUsedUnit])
        MemoryLimitBytes = [long][Math]::Round($taskLimit * $taskUnits[$taskLimitUnit])
        MemoryPercent = [double]::Parse($taskMemoryPercentMatch.Value, $taskCulture)
    }
}

function Stop-BenchmarkResourceCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Capture
    )
    $taskEncoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Capture.StopPath, 'stop', $taskEncoding)
    $taskJob = Get-Job -Id $Capture.JobId -ErrorAction SilentlyContinue
    if ($taskJob) {
        $taskJob = Wait-Job -Id $Capture.JobId -Timeout 15
        if (-not $taskJob) {
            Stop-Job -Id $Capture.JobId -ErrorAction SilentlyContinue
            Remove-Job -Id $Capture.JobId -Force -ErrorAction SilentlyContinue
            throw 'Docker resource sampler did not stop within 15 seconds.'
        }
        $taskJobOutput = Receive-Job -Id $Capture.JobId -ErrorAction SilentlyContinue
        $taskJobState = $taskJob.State
        Remove-Job -Id $Capture.JobId -Force -ErrorAction SilentlyContinue
        if ($taskJobState -eq 'Failed') {
            throw ('Docker resource sampler failed: ' + ($taskJobOutput -join ' '))
        }
    }
    if (Test-Path -LiteralPath $Capture.ErrorPath) {
        $taskErrors = Get-Content -LiteralPath $Capture.ErrorPath
        if ($taskErrors.Count -gt 0) {
            throw ('Docker resource sampler reported an error: ' + ($taskErrors -join ' '))
        }
    }
    if (-not (Test-Path -LiteralPath $Capture.OutputPath)) {
        throw ('Docker resource sampler captured no containers for Compose project ' + $Capture.ProjectName)
    }
    $taskSamples = @()
    foreach ($taskLine in Get-Content -LiteralPath $Capture.OutputPath) {
        if ([string]::IsNullOrWhiteSpace($taskLine)) {
            continue
        }
        $taskSamples += ConvertFrom-DockerStatsSample -Line $taskLine
    }
    if ($taskSamples.Count -eq 0) {
        throw ('Docker resource sampler captured no samples for Compose project ' + $Capture.ProjectName)
    }
    $taskContainers = @()
    foreach ($taskGroup in ($taskSamples | Group-Object -Property Container)) {
        $taskRows = @($taskGroup.Group)
        $taskCPUs = [double[]]@($taskRows | ForEach-Object { $_.CPUPercent })
        $taskMemoryUsages = [double[]]@($taskRows | ForEach-Object { $_.MemoryUsageBytes })
        $taskMemoryPercents = [double[]]@($taskRows | ForEach-Object { $_.MemoryPercent })
        $taskContainers += [pscustomobject]@{
            container = $taskGroup.Name
            container_id = $taskRows[0].ContainerID
            samples = $taskRows.Count
            cpu_percent_mean = [Math]::Round(($taskCPUs | Measure-Object -Average).Average, 3)
            cpu_percent_max = [Math]::Round(($taskCPUs | Measure-Object -Maximum).Maximum, 3)
            memory_usage_bytes_mean = [Math]::Round(($taskMemoryUsages | Measure-Object -Average).Average, 0)
            memory_usage_bytes_max = [long](($taskMemoryUsages | Measure-Object -Maximum).Maximum)
            memory_limit_bytes = $taskRows[-1].MemoryLimitBytes
            memory_percent_mean = [Math]::Round(($taskMemoryPercents | Measure-Object -Average).Average, 3)
            memory_percent_max = [Math]::Round(($taskMemoryPercents | Measure-Object -Maximum).Maximum, 3)
            first_sample_utc = $taskRows[0].SampledAtUtc.ToString('o')
            last_sample_utc = $taskRows[-1].SampledAtUtc.ToString('o')
        }
    }
    $taskSummary = [ordered]@{
        project = $Capture.ProjectName
        started_at_utc = $Capture.StartedAt.ToString('o')
        stopped_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        interval_seconds = $Capture.IntervalSeconds
        total_samples = $taskSamples.Count
        raw_samples_path = $Capture.OutputPath
        containers = @($taskContainers)
    }
    $taskSummaryPath = $Capture.OutputPath + '.summary.json'
    [IO.File]::WriteAllText(
        $taskSummaryPath,
        ($taskSummary | ConvertTo-Json -Depth 8) + [Environment]::NewLine,
        $taskEncoding
    )
    Remove-Item -LiteralPath $Capture.StopPath -Force -ErrorAction SilentlyContinue
    [pscustomobject]$taskSummary
}

Export-ModuleMember -Function Start-BenchmarkResourceCapture, Stop-BenchmarkResourceCapture, ConvertFrom-DockerStatsSample
