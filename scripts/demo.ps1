[CmdletBinding()]
param([switch]$SkipDownload)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'first-steps.ps1') -SkipDownload:$SkipDownload
& (Join-Path $PSScriptRoot 'train-demo.ps1')
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $taskRepo
try {
    $taskCompose = (docker compose config --format json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo resolver Compose.' }
    $taskURL = 'http://127.0.0.1:' + $taskCompose.services.web.ports[0].published
    $taskExpectedVersion = (Get-Content -LiteralPath data/training-distributed.json -Raw | ConvertFrom-Json).artifact.version
    . (Join-Path $PSScriptRoot 'session.ps1')
    $taskHeaders=Get-DemoAuthorization $taskURL
    $taskLimit = [datetime]::UtcNow.AddSeconds(30)
    do {
        $taskModel = Invoke-RestMethod ($taskURL + '/api/v1/models/current') -Headers $taskHeaders
        if ($taskModel.ready -and $taskModel.version -eq $taskExpectedVersion) { break }
        Start-Sleep -Milliseconds 500
    } while ([datetime]::UtcNow -lt $taskLimit)
    if (-not $taskModel.ready -or $taskModel.version -ne $taskExpectedVersion) { throw 'La API todavía no cargó la versión entrenada. Revisa su estado.' }
    & (Join-Path $PSScriptRoot 'check-demo.ps1')
    & (Join-Path $PSScriptRoot 'check-weeks-7-10.ps1')
    Write-Host ('Demo lista: ' + $taskURL)
} finally { Pop-Location }
