function Get-DemoAuthorization([string]$Base) {
    $taskRepo=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $taskValues=@{}
    foreach($taskLine in Get-Content -LiteralPath (Join-Path $taskRepo '.env')) {
        if($taskLine -match '^([A-Z_]+)=(.*)$'){$taskValues[$Matches[1]]=$Matches[2]}
    }
    $taskLogin=Invoke-RestMethod ($Base+'/api/v1/auth/login') -Method Post -ContentType application/json -Body (@{username=$taskValues.DEMO_USER;password=$taskValues.DEMO_PASSWORD}|ConvertTo-Json)
    return @{Authorization='Bearer '+$taskLogin.access_token}
}
