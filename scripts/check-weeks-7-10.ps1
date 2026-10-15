[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$taskRepo=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $taskRepo
$taskSocket=$null
$taskTimeout=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
try {
    $taskConfig=(docker compose config --format json)|ConvertFrom-Json
    if($LASTEXITCODE -ne 0){throw 'No se pudo resolver Compose.'}
    $taskBase='http://127.0.0.1:'+$taskConfig.services.web.ports[0].published
    $taskAnonymous=0
    try {Invoke-RestMethod ($taskBase+'/api/v1/datasets/current')|Out-Null}catch{$taskAnonymous=[int]$_.Exception.Response.StatusCode}
    if($taskAnonymous -ne 401){throw 'La API permite acceso sin JWT.'}
    . (Join-Path $PSScriptRoot 'session.ps1')
    $taskHeaders=Get-DemoAuthorization $taskBase
    $taskDataset=Invoke-RestMethod ($taskBase+'/api/v1/datasets/current') -Headers $taskHeaders
    $taskModel=Invoke-RestMethod ($taskBase+'/api/v1/models/current') -Headers $taskHeaders
    if($taskDataset.stats.persisted -lt 1000000){throw 'Falta el millón de registros válidos.'}
    if(-not $taskModel.ready -or $taskModel.dataset_id -ne $taskDataset.dataset_id){throw 'Falta un modelo del dataset actual.'}
    $taskRun=Invoke-RestMethod ($taskBase+'/api/v1/training-runs/'+$taskModel.version) -Headers $taskHeaders
    if($taskRun.status -ne 'completed' -or $taskRun.mode -ne 'distributed' -or $taskRun.dataset_id -ne $taskDataset.dataset_id -or $taskRun.artifact_version -ne $taskModel.version){throw 'Falta un entrenamiento distribuido completo para el modelo activo.'}
    if(@($taskRun.workers).Count -ne 2 -or @($taskRun.workers|Select-Object -Unique).Count -ne 2){throw 'El entrenamiento debe registrar dos workers distintos.'}
    foreach($taskWorkerID in $taskRun.workers){
        $taskContribution=$taskRun.tasks_by_worker.PSObject.Properties[$taskWorkerID]
        if(-not $taskContribution -or $taskContribution.Value -le 0){throw 'Un worker no aportó gradientes al entrenamiento.'}
    }
    if($taskRun.progress.total_steps -le 0 -or $taskRun.progress.step -ne $taskRun.progress.total_steps){throw 'El entrenamiento no llegó al último paso.'}
    $taskImpact=Invoke-RestMethod ($taskBase+'/api/v1/impact') -Headers $taskHeaders
    if($taskImpact.total_observed_trips -ne $taskDataset.stats.persisted){throw 'Los agregados de impacto no coinciden con los datos.'}
    $taskTampered=@{Authorization=$taskHeaders.Authorization+'x'}
    $taskTamperedStatus=0
    try {Invoke-RestMethod ($taskBase+'/api/v1/models/current') -Headers $taskTampered|Out-Null}catch{$taskTamperedStatus=[int]$_.Exception.Response.StatusCode}
    if($taskTamperedStatus -ne 401){throw 'La API acepta un JWT modificado.'}
    $taskSocket=[Net.WebSockets.ClientWebSocket]::new()
    $taskSocket.Options.SetRequestHeader('Authorization',$taskHeaders.Authorization)
    $taskSocket.Options.SetRequestHeader('Origin',$taskBase)
    $taskSocket.ConnectAsync([uri]($taskBase.Replace('http:','ws:')+'/api/v1/events'),$taskTimeout.Token).GetAwaiter().GetResult()|Out-Null
    function Read-DemoEvent {
        $taskBuffer=New-Object byte[] 65536
        $taskStream=[IO.MemoryStream]::new()
        try {
            do {
                $taskReceived=$taskSocket.ReceiveAsync([ArraySegment[byte]]::new($taskBuffer),$taskTimeout.Token).GetAwaiter().GetResult()
                if($taskReceived.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){return @{closed=$true;status=[int]$taskReceived.CloseStatus}}
                $taskStream.Write($taskBuffer,0,$taskReceived.Count)
                if($taskStream.Length -gt 1048576){throw 'Evento demasiado grande.'}
            }while(-not $taskReceived.EndOfMessage)
            return [Text.Encoding]::UTF8.GetString($taskStream.ToArray())|ConvertFrom-Json
        }finally{$taskStream.Dispose()}
    }
    do {$taskSnapshot=Read-DemoEvent}while($taskSnapshot.type -ne 'snapshot' -or -not $taskSnapshot.cluster.master.available -or @($taskSnapshot.cluster.workers|Where-Object{-not $_.telemetry.available}).Count -gt 0)
    if($taskSnapshot.cluster.workers.Count -ne 2){throw 'No se detectan dos trabajadores.'}
    if(@($taskSnapshot.cluster.workers.worker_id|Select-Object -Unique).Count -ne 2){throw 'El clúster no registra workers distintos.'}
    foreach($taskSample in @($taskSnapshot.cluster.master)+@($taskSnapshot.cluster.workers.telemetry)){
        $taskSampleAge=([DateTimeOffset]::UtcNow-[DateTimeOffset]$taskSample.sampled_at).TotalSeconds
        if($taskSampleAge -lt -5 -or $taskSampleAge -gt 7 -or $taskSample.rss_bytes -le 0){throw 'La telemetría no tiene RAM y muestras recientes.'}
    }
    $taskOrigin=if($taskModel.last_origin -is [datetime]){([datetimeoffset]$taskModel.last_origin).ToString('o')}else{$taskModel.last_origin}
    $taskRequest=@{type='predict';request_id='smoke-prediction';request=@{dataset_id=$taskDataset.dataset_id;zone_id=161;forecast_origin=$taskOrigin;horizon_minutes=15}}|ConvertTo-Json -Depth 5 -Compress
    $taskBytes=[Text.Encoding]::UTF8.GetBytes($taskRequest)
    $taskSocket.SendAsync([ArraySegment[byte]]::new($taskBytes),[Net.WebSockets.WebSocketMessageType]::Text,$true,$taskTimeout.Token).GetAwaiter().GetResult()|Out-Null
    do {$taskEvent=Read-DemoEvent}while($taskEvent.type -ne 'prediction')
    if($taskEvent.error -or $taskEvent.prediction.model_version -ne $taskModel.version){throw 'Falló la predicción WebSocket.'}
    $taskPredictionBody=@{dataset_id=$taskDataset.dataset_id;zone_id=161;forecast_origin=$taskOrigin;horizon_minutes=15}|ConvertTo-Json
    Invoke-RestMethod ($taskBase+'/api/v1/predictions') -Method Post -ContentType application/json -Body $taskPredictionBody -Headers $taskHeaders|Out-Null
    $taskCached=Invoke-RestMethod ($taskBase+'/api/v1/predictions') -Method Post -ContentType application/json -Body $taskPredictionBody -Headers $taskHeaders
    if(-not $taskCached.cache_hit -or $taskCached.model_version -ne $taskModel.version){throw 'Redis no está reutilizando la predicción de la versión activa.'}
    Invoke-RestMethod ($taskBase+'/api/v1/auth/logout') -Method Post -ContentType application/json -Body '{}' -Headers $taskHeaders|Out-Null
    do {$taskEnd=Read-DemoEvent}while(-not $taskEnd.closed)
    if($taskEnd.status -ne 1008){throw 'El cierre de sesión no revocó el WebSocket.'}
    $taskLogoutStatus=0
    try{Invoke-RestMethod ($taskBase+'/api/v1/auth/session') -Headers $taskHeaders|Out-Null}catch{$taskLogoutStatus=[int]$_.Exception.Response.StatusCode}
    if($taskLogoutStatus -ne 401){throw 'El JWT sigue válido después de salir.'}
    $taskReport=@{verified_at=[DateTimeOffset]::UtcNow.ToString('o');dataset_id=$taskDataset.dataset_id;accepted_trips=$taskDataset.stats.persisted;anonymous_status=$taskAnonymous;tampered_jwt_status=$taskTamperedStatus;logout_status=$taskLogoutStatus;websocket_close_status=$taskEnd.status;streamed_prediction=$taskEvent.prediction;redis_cached_prediction=$taskCached;distributed_training=$taskRun;telemetry=$taskSnapshot.cluster;impact=$taskImpact;frontend='React production build; browser verification separately'}
    [IO.File]::WriteAllText((Join-Path $taskRepo 'data/weeks-7-10-check.json'),($taskReport|ConvertTo-Json -Depth 10))
    Write-Host ('Semanas 7 a 10: '+$taskDataset.stats.persisted+' registros; JWT, WebSocket, telemetría e impacto verificados.')
}finally{if($taskSocket){$taskSocket.Abort();$taskSocket.Dispose()};$taskTimeout.Dispose();Pop-Location}
