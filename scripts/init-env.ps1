[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$taskRepo=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$taskPath=Join-Path $taskRepo '.env'
$taskExisting=if(Test-Path -LiteralPath $taskPath){[IO.File]::ReadAllText($taskPath)}else{''}
$taskDefaults=[ordered]@{API_PORT='8080';WEB_PORT='3000';MONGO_DATABASE='transporte';DEMO_USER='demo'}
foreach($taskKey in @('JWT_SECRET','MASTER_API_TOKEN','DEMO_PASSWORD')){
 $taskRandom=New-Object byte[] 32
 $taskGenerator=[Security.Cryptography.RandomNumberGenerator]::Create()
 try{$taskGenerator.GetBytes($taskRandom)}finally{$taskGenerator.Dispose()}
 $taskDefaults[$taskKey]=[Convert]::ToBase64String($taskRandom)
}
foreach($taskKey in $taskDefaults.Keys){
 $taskPattern='(?m)^'+[regex]::Escape($taskKey)+'=(.*)$'
 $taskMatch=[regex]::Match($taskExisting,$taskPattern)
 if(-not $taskMatch.Success){$taskExisting+=[Environment]::NewLine+$taskKey+'='+$taskDefaults[$taskKey]}
 elseif([string]::IsNullOrWhiteSpace($taskMatch.Groups[1].Value)){$taskExisting=[regex]::Replace($taskExisting,$taskPattern,$taskKey+'='+$taskDefaults[$taskKey])}
}
[IO.File]::WriteAllText($taskPath,$taskExisting.Trim()+[Environment]::NewLine)
Write-Host 'Credenciales locales listas en .env. No se muestran ni se guardan en Git.'
