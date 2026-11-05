[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $taskRepo
try {
    $taskErrors = @()
    $taskDocker = Get-Command docker -ErrorAction SilentlyContinue
    $taskDockerInfo = $null
    $taskDockerVersion = $null
    $taskComposeVersion = $null
    $taskRunningServices = @()

    if (-not $taskDocker) {
        $taskErrors += 'Docker CLI was not found.'
    } else {
        $taskDockerInfoText = docker info --format '{{json .}}' 2>&1
        if ($LASTEXITCODE -eq 0) {
            $taskDockerInfo = ($taskDockerInfoText -join [Environment]::NewLine) | ConvertFrom-Json
            if ($taskDockerInfo.OSType -ne 'linux') {
                $taskErrors += 'Docker must use the Linux engine.'
            }
        } else {
            $taskErrors += 'Docker Engine is not responding.'
        }

        $taskDockerVersion = docker version --format '{{.Client.Version}}|{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -ne 0) {
            $taskErrors += 'Docker client/server versions could not be read.'
        }
        $taskComposeVersion = docker compose version --short 2>&1
        if ($LASTEXITCODE -ne 0) {
            $taskErrors += 'Docker Compose is not available.'
        } else {
            docker compose config --quiet
            if ($LASTEXITCODE -ne 0) {
                $taskErrors += 'The project Compose configuration is invalid.'
            }
            $taskRunningServices = @(docker compose ps --status running --services 2>&1 | Where-Object { $_ -and $_.Trim() })
            if ($LASTEXITCODE -ne 0) {
                $taskErrors += 'Could not check whether the project services are running.'
            } elseif ($taskRunningServices.Count -gt 0) {
                $taskErrors += 'Stop the project demo before starting benchmark measurements.'
            }
        }
    }

    $taskSources = Get-Content -LiteralPath 'configs/sources.json' -Raw | ConvertFrom-Json
    $taskDataChecks = @($taskSources.files | ForEach-Object {
        $taskPath = Join-Path 'data/raw' $_.name
        $taskPresent = Test-Path -LiteralPath $taskPath
        $taskActualHash = $null
        if ($taskPresent) {
            $taskActualHash = (Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $taskVerified = $taskPresent -and $taskActualHash -eq $_.sha256
        if (-not $taskPresent) {
            $taskErrors += ('Required source file is missing: ' + $_.name)
        } elseif (-not $taskVerified) {
            $taskErrors += ('Source checksum mismatch: ' + $_.name)
        }
        [pscustomobject]@{
            file = $_.name
            expected_sha256 = $_.sha256
            actual_sha256 = $taskActualHash
            present = $taskPresent
            checksum_verified = $taskVerified
        }
    })

    $taskConfigs = @('configs/demo.json', 'configs/training.json') | ForEach-Object {
        [pscustomobject]@{
            file = $_
            sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $taskCommit = (git rev-parse HEAD 2>&1) -join ''
    if ($LASTEXITCODE -ne 0) {
        $taskErrors += 'Could not identify the current Git commit.'
    }
    $taskBranch = (git branch --show-current 2>&1) -join ''
    $taskDirty = @(git status --porcelain 2>&1).Count -gt 0

    $taskReport = [ordered]@{
        checked_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        ready_for_measurements = ($taskErrors.Count -eq 0)
        errors = @($taskErrors)
        repository = [ordered]@{
            commit = $taskCommit
            branch = $taskBranch
            worktree_dirty = $taskDirty
        }
        host = [ordered]@{
            os = [Environment]::OSVersion.VersionString
            logical_processors = [Environment]::ProcessorCount
        }
        docker = [ordered]@{
            client_server_version = ($taskDockerVersion -join '')
            compose_version = ($taskComposeVersion -join '')
            engine_os = if ($taskDockerInfo) { $taskDockerInfo.OSType } else { $null }
            engine_cpus = if ($taskDockerInfo) { $taskDockerInfo.NCPU } else { $null }
            engine_memory_bytes = if ($taskDockerInfo) { $taskDockerInfo.MemTotal } else { $null }
            running_project_services = @($taskRunningServices)
        }
        configs = @($taskConfigs)
        source_data = @($taskDataChecks)
        scope = 'Preflight only; no benchmark workload or project service was started.'
    }
    $taskOutputPath = Join-Path $taskRepo 'data/benchmark-preflight.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $taskOutputPath) | Out-Null
    [IO.File]::WriteAllText($taskOutputPath, ($taskReport | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Write-Host ('Preflight report: ' + $taskOutputPath)
    if (-not $taskReport.ready_for_measurements) {
        throw ('Benchmark preflight failed: ' + ($taskErrors -join ' '))
    }
    Write-Host 'Preflight passed. No services were started and no performance results were produced.'
} finally {
    Pop-Location
}
