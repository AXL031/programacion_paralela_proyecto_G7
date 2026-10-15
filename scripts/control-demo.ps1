[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Stop')]
    [string]$Action,
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$taskDocker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $taskDocker) {
    foreach ($taskBin in @(
        (Join-Path $env:ProgramFiles 'Docker/Docker/resources/bin'),
        (Join-Path $env:LOCALAPPDATA 'Programs/DockerDesktop/resources/bin')
    )) {
        if (Test-Path -LiteralPath (Join-Path $taskBin 'docker.exe')) {
            $env:PATH = $taskBin + [IO.Path]::PathSeparator + $env:PATH
            $taskDocker = Get-Command docker -ErrorAction SilentlyContinue
            break
        }
    }
}
if (-not $taskDocker) { throw 'No se encuentra Docker Desktop. Instala Docker antes de abrir la demo.' }

function Get-DemoEngine {
    # Bound each probe: Docker may keep a client waiting while WSL starts.
    $taskProbe = New-Object Diagnostics.Process
    $taskProbe.StartInfo.FileName = $taskDocker.Source
    $taskProbe.StartInfo.Arguments = 'info --format {{.OSType}}'
    $taskProbe.StartInfo.UseShellExecute = $false
    $taskProbe.StartInfo.CreateNoWindow = $true
    $taskProbe.StartInfo.RedirectStandardOutput = $true
    $taskProbe.StartInfo.RedirectStandardError = $true
    try {
        [void]$taskProbe.Start()
        $taskOutput = $taskProbe.StandardOutput.ReadToEndAsync()
        $taskError = $taskProbe.StandardError.ReadToEndAsync()
        if (-not $taskProbe.WaitForExit(5000)) {
            $taskProbe.Kill()
            $taskProbe.WaitForExit()
            return ''
        }
        if ($taskProbe.ExitCode -eq 0) { return $taskOutput.GetAwaiter().GetResult().Trim() }
        return ''
    } finally { $taskProbe.Dispose() }
}

Push-Location $taskRepo
try {
    if (-not (Test-Path -LiteralPath '.env')) { throw 'Falta preparar esta copia: ejecuta scripts/prepare-local.ps1 -StartDemo una vez.' }
    if ($Action -eq 'Stop') {
        Write-Host 'Apagando el sistema G7...'
        $taskEngine = Get-DemoEngine
        if (-not $taskEngine) {
            $taskDesktopProcesses = @(Get-Process -Name 'Docker Desktop', 'com.docker.backend' -ErrorAction SilentlyContinue)
            if ($taskDesktopProcesses.Count -gt 0) {
                throw 'Docker Desktop sigue abierto, pero su motor no responde. Revisa Docker y vuelve a intentar el apagado.'
            }
            Write-Host 'El sistema y Docker Desktop ya estan apagados.'
            return
        }
        docker compose --profile '*' down --remove-orphans --timeout 15
        if ($LASTEXITCODE -ne 0) { throw 'No se pudieron detener todos los contenedores del proyecto.' }
        $taskRemaining = @(docker ps -q)
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo comprobar si hay otros contenedores trabajando.' }
        if ($taskRemaining.Count -eq 0) {
            Write-Host 'Cerrando Docker Desktop y su motor Linux...'
            docker desktop stop --timeout 120
            if ($LASTEXITCODE -ne 0) { throw 'El proyecto esta apagado, pero Docker Desktop no termino de cerrar.' }
            Write-Host 'Sistema y Docker Desktop apagados. Datos y modelos conservados.'
        } else {
            Write-Host 'Sistema G7 apagado. Docker permanece abierto porque hay otros contenedores trabajando.'
        }
        return
    }

    Write-Host 'Iniciando el sistema G7...'
    $taskEngine = Get-DemoEngine
    if (-not $taskEngine) {
        Write-Host 'Iniciando Docker Desktop; el primer arranque puede tardar...'
        docker desktop start --detach
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo iniciar Docker Desktop.' }
        $taskLimit = [DateTime]::UtcNow.AddMinutes(3)
        do {
            $taskEngine = Get-DemoEngine
            if ($taskEngine) { break }
            Start-Sleep -Seconds 2
        } while ([DateTime]::UtcNow -lt $taskLimit)
    }
    if ($taskEngine -ne 'linux') { throw 'Docker no esta listo con motor Linux. Abre Docker Desktop y revisa su estado.' }

    # Everyday startup reuses prepared images, MongoDB and the published model.
    docker compose up -d --no-build --pull never --scale worker=2 --wait --wait-timeout 120
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo iniciar el sistema. Si faltan imagenes, ejecuta scripts/prepare-local.ps1 -StartDemo.' }
    $taskConfigText = docker compose config --format json
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo resolver la configuracion de Compose.' }
    $taskConfig = ($taskConfigText -join [Environment]::NewLine) | ConvertFrom-Json
    $taskURL = 'http://127.0.0.1:' + $taskConfig.services.web.ports[0].published
    . (Join-Path $PSScriptRoot 'session.ps1')
    $taskHeaders = Get-DemoAuthorization $taskURL
    try {
        $taskLimit = [DateTime]::UtcNow.AddSeconds(45)
        do {
            $taskModel = Invoke-RestMethod ($taskURL + '/api/v1/models/current') -Headers $taskHeaders -TimeoutSec 10
            $taskDataset = Invoke-RestMethod ($taskURL + '/api/v1/datasets/current') -Headers $taskHeaders -TimeoutSec 10
            $taskCluster = Invoke-RestMethod ($taskURL + '/api/v1/cluster') -Headers $taskHeaders -TimeoutSec 10
            $taskReady = $taskModel.ready -and $taskModel.dataset_id -eq $taskDataset.dataset_id -and @($taskCluster.workers).Count -eq 2
            if ($taskReady) { break }
            Start-Sleep -Seconds 1
        } while ([DateTime]::UtcNow -lt $taskLimit)
        if (-not $taskReady) { throw 'El sistema inicio, pero falta el modelo publicado o los dos workers. Revisa la preparacion de la demo.' }
        Write-Host ('Demo lista: ' + $taskURL)
        Write-Host ('Viajes persistidos: ' + $taskDataset.stats.persisted + '; workers conectados: ' + @($taskCluster.workers).Count)
    } finally {
        Invoke-RestMethod ($taskURL + '/api/v1/auth/logout') -Method Post -ContentType application/json -Body '{}' -Headers $taskHeaders -TimeoutSec 10 | Out-Null
    }
    if (-not $NoBrowser) { Start-Process $taskURL }
} finally { Pop-Location }
