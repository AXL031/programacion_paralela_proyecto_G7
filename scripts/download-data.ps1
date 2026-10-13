[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$taskRaw = Join-Path $taskRepo 'data/raw'
New-Item -ItemType Directory -Force -Path $taskRaw | Out-Null
$taskSourceConfig = Get-Content -LiteralPath (Join-Path $taskRepo 'configs/sources.json') -Raw | ConvertFrom-Json
$taskSources = $taskSourceConfig.files
$taskEntries = @()
foreach ($taskSource in $taskSources) {
    $taskFile = Join-Path $taskRaw $taskSource.Name
    $taskHashFile = $taskFile + '.sha256'
    if (-not (Test-Path -LiteralPath $taskFile)) {
        $taskPartial = $taskFile + '.partial'
        Write-Host ('Descargando ' + $taskSource.Name)
        Invoke-WebRequest -Uri $taskSource.URL -OutFile $taskPartial -TimeoutSec 300
        Move-Item -LiteralPath $taskPartial -Destination $taskFile
    }
    $taskHash = (Get-FileHash -LiteralPath $taskFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($taskHash -ne $taskSource.sha256) { throw ('El archivo no coincide con la fuente fijada en configs/sources.json: ' + $taskSource.Name) }
    if (Test-Path -LiteralPath $taskHashFile) {
        if ((Get-Content -LiteralPath $taskHashFile -Raw).Trim() -ne $taskHash) { throw ('Checksum no coincide: ' + $taskSource.Name) }
    } else {
        # This checksum matches the versioned project source manifest.
        [IO.File]::WriteAllText($taskHashFile, $taskHash + [Environment]::NewLine)
    }
    $taskEntries += @{ file = $taskSource.Name; url = $taskSource.URL; sha256 = $taskHash; bytes = (Get-Item -LiteralPath $taskFile).Length }
}
$taskManifest = @{ source = 'NYC TLC'; checksum_policy = $taskSourceConfig.checksum_policy; files = $taskEntries }
[IO.File]::WriteAllText((Join-Path $taskRaw 'download-manifest.json'), ($taskManifest | ConvertTo-Json -Depth 5))
Write-Host 'Datos descargados y checksums verificados.'
