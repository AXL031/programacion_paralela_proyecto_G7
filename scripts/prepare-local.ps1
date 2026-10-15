[CmdletBinding()]
param([switch]$StartDemo)
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $taskRepo
try {
    & (Join-Path $PSScriptRoot 'init-env.ps1')
    New-Item -ItemType Directory -Force -Path data | Out-Null
    $taskSources = (Get-Content configs/sources.json -Raw | ConvertFrom-Json).files
    $taskData = @($taskSources | ForEach-Object {
        $taskFile = Join-Path $taskRepo ('data/raw/' + $_.name)
        $taskPresent = Test-Path -LiteralPath $taskFile
        $taskVerified = $false
        if ($taskPresent) { $taskVerified = (Get-FileHash -LiteralPath $taskFile -Algorithm SHA256).Hash.ToLowerInvariant() -eq $_.sha256 }
        [pscustomobject]@{ file = $_.name; present = $taskPresent; checksum_verified = $taskVerified }
    })
    $taskDocker = Get-Command docker -ErrorAction SilentlyContinue
    # A newly installed Docker Desktop may not be on this terminal's PATH yet.
    if (-not $taskDocker) {
        $taskDockerPaths = @(
            (Join-Path $env:ProgramFiles 'Docker/Docker/resources/bin'),
            (Join-Path $env:LOCALAPPDATA 'Programs/DockerDesktop/resources/bin')
        )
        foreach ($taskDockerPath in $taskDockerPaths) {
            if (Test-Path -LiteralPath (Join-Path $taskDockerPath 'docker.exe')) {
                $env:PATH = $taskDockerPath + [IO.Path]::PathSeparator + $env:PATH
                $taskDocker = Get-Command docker -ErrorAction SilentlyContinue
                break
            }
        }
    }
    $taskEngine = $false
    $taskCompose = $false
    $taskLinux = $false
    if ($taskDocker) {
        $taskInfo = docker info --format '{{.OSType}}' 2>$null
        $taskEngine = $LASTEXITCODE -eq 0
        $taskLinux = $taskEngine -and ($taskInfo -join '').Trim() -eq 'linux'
        docker compose version | Out-Host
        $taskCompose = $LASTEXITCODE -eq 0
    }
    $taskReport = [ordered]@{
        checked_at = [DateTimeOffset]::UtcNow.ToString('o')
        credentials_prepared = Test-Path -LiteralPath .env
        docker_cli_found = [bool]$taskDocker
        docker_engine_ready = $taskEngine
        linux_engine = $taskLinux
        compose_available = $taskCompose
        raw_data = $taskData
        demo_verified = $false
        go_checks_verified = $false
        scope = 'Local preparation; raw files do not prove MongoDB ingestion or training.'
    }
    $taskReportPath = Join-Path $taskRepo 'data/local-preparation.json'
    [IO.File]::WriteAllText($taskReportPath, ($taskReport | ConvertTo-Json -Depth 6))
    if (-not ($taskEngine -and $taskLinux -and $taskCompose)) {
        $taskMessage = 'Falta Docker Desktop iniciado con motor Linux y Docker Compose. Después ejecuta ./scripts/prepare-local.ps1 -StartDemo.'
        if ($StartDemo) { throw $taskMessage }
        Write-Host $taskMessage
        return
    }
    docker compose config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'La configuración de Compose es inválida.' }
    if (-not $StartDemo) {
        Write-Host 'Entorno preparado. Ejecuta ./scripts/prepare-local.ps1 -StartDemo para cargar, entrenar y verificar.'
        return
    }
    # download-data verifies existing files too, so the first run is safe to repeat.
    & (Join-Path $PSScriptRoot 'demo.ps1')
    $taskReport.demo_verified = $true
    [IO.File]::WriteAllText($taskReportPath, ($taskReport | ConvertTo-Json -Depth 6))
    $taskUnformatted = docker compose --profile tools run --rm dev gofmt -l cmd internal tests/integration web
    if ($LASTEXITCODE -ne 0 -or $taskUnformatted) { throw 'La comprobación de formato Go falló.' }
    docker compose --profile tools run --rm dev go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'go vet falló.' }
    docker compose --profile tools run --rm dev go test -race -count=1 ./...
    if ($LASTEXITCODE -ne 0) { throw 'Las pruebas Go con detector de carreras fallaron.' }
    $taskReport.go_checks_verified = $true
    $taskReport.scope = 'Fresh local demo checks and Go checks; browser presentation still requires visual review.'
    [IO.File]::WriteAllText($taskReportPath, ($taskReport | ConvertTo-Json -Depth 6))
    Write-Host 'Demo y pruebas verificadas. Abre la URL mostrada por demo.ps1 y revisa el panel en el navegador.'
} finally { Pop-Location }
