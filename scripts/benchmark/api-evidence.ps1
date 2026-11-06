function Assert-BenchAPIEvidence($Context,$Plan,$Result){
    $m=$Result.metrics
    foreach($key in @('requests_path','requests_sha256','model_version','throughput_total','throughput_success','proportion_under_100_ms')){if(-not $m.Contains($key)){throw "Missing raw HTTP evidence: $key"}}
    $path=Resolve-BenchPath (Resolve-BenchPath $m.requests_path) $Context.raw_dir
    if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $m.requests_sha256){throw 'HTTP request evidence checksum mismatch.'}
    $raw=Read-BenchJson $path
    if($raw.dataset_id -cne $Result.dataset.id -or $raw.model_version -cne $m.model_version -or $raw.scenario -cne $Plan.parameters.cache -or $raw.concurrency -ne $Plan.parameters.concurrency){throw 'Raw HTTP identity/scenario mismatch.'}
    $rows=@($raw.samples)
    if($rows.Count -ne $Plan.parameters.requests -or @($rows.index|Sort-Object -Unique).Count -ne $rows.Count){throw 'Missing/duplicated HTTP attempts.'}
    $latencies=@();$hits=0;$under=0;$errors=0;$succeeded=0;$timeouts=0;$errorCounts=@{};$errorLatencies=@()
    foreach($row in $rows){
        if($row.success -isnot [bool] -or $row.cache_hit -isnot [bool] -or $row.timeout -isnot [bool]){throw 'Invalid raw attempt types.'}
        $t=[double]$row.latency_ms
        if(-not [double]::IsFinite($t) -or $t -lt 0){throw 'Invalid HTTP latency.'}
        $latencies+=$t;if($row.cache_hit){$hits++};if($row.timeout){$timeouts++}
        $expectedHit=$Plan.parameters.cache -eq 'warm'
        if($row.success){
            if($row.http_status -ne 200 -or $row.timeout -or $row.cache_hit -ne $expectedHit -or ($row.Contains('error') -and $row.error)){throw 'Successful raw request hides an error or cache deviation.'}
            $succeeded++;if($t -lt 100){$under++}
        }else{
            if(-not $row.Contains('error') -or -not $row.error){throw 'Unsuccessful raw attempt has no error cause.'}
            $errors++;$errorLatencies+=$t
            $reason=[string]$row.error
            if(-not $errorCounts.Contains($reason)){$errorCounts[$reason]=0};$errorCounts[$reason]++
        }
    }
    $sorted=@($latencies|Sort-Object)
    foreach($entry in @(@('p50_ms',.50),@('p95_ms',.95),@('p99_ms',.99),@('max_ms',1.0))){
        $value=$sorted[[int][Math]::Ceiling($entry[1]*$rows.Count)-1]
        if([Math]::Abs([double]$m[$entry[0]]-$value) -gt 1e-9){throw "HTTP percentile is not traceable: $($entry[0])"}
    }
    if($hits -ne $m.cache_hits -or $errors -ne $m.errors -or $succeeded -ne $m.succeeded -or $timeouts -ne $m.timeouts){throw 'Raw HTTP cache/error counters do not match metrics.'}
    foreach($report in @($raw,$m)){
        if((@($report.error_counts.Keys|Sort-Object)-join ',') -cne (@($errorCounts.Keys|Sort-Object)-join ',')){throw 'Error reasons omitted from report.'}
        foreach($reason in $errorCounts.Keys){if($report.error_counts[$reason] -ne $errorCounts[$reason]){throw 'Incorrect error reason count.'}}
        if((@($report.error_latencies_ms)|ConvertTo-Json -Compress) -cne (@($errorLatencies)|ConvertTo-Json -Compress)){throw 'Error latency evidence mismatch.'}
    }
    if($raw.elapsed_seconds -le 0 -or [Math]::Abs($m.throughput_total-$rows.Count/$raw.elapsed_seconds) -gt 1e-6 -or [Math]::Abs($m.throughput_success-$succeeded/$raw.elapsed_seconds) -gt 1e-6 -or [Math]::Abs($m.proportion_under_100_ms-$under/$rows.Count) -gt 1e-12){throw 'Invalid HTTP throughput/proportion.'}
}
