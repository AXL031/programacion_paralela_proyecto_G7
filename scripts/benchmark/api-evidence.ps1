function Assert-BenchAPIEvidence($Context,$Plan,$Result){
    $m=$Result.metrics
    foreach($key in @('requests_path','requests_sha256','model_version','throughput_total','throughput_success','proportion_under_100_ms')){if(-not $m.Contains($key)){throw "Missing raw HTTP evidence: $key"}}
    $path=Resolve-BenchPath (Resolve-BenchPath $m.requests_path) $Context.raw_dir
    if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $m.requests_sha256){throw 'HTTP request evidence checksum mismatch.'}
    $raw=Read-BenchJson $path
    if($raw.dataset_id -cne $Result.dataset.id -or $raw.model_version -cne $m.model_version -or $raw.scenario -cne $Plan.parameters.cache -or $raw.concurrency -ne $Plan.parameters.concurrency){throw 'Raw HTTP identity/scenario mismatch.'}
    $rows=@($raw.samples)
    if($rows.Count -ne $Plan.parameters.requests -or @($rows.index|Sort-Object -Unique).Count -ne $rows.Count){throw 'Missing/duplicated HTTP attempts.'}
    $latencies=@();$hits=0;$under=0
    foreach($row in $rows){
        if(-not $row.success -or $row.http_status -ne 200 -or $row.timeout){throw 'Raw HTTP errors cannot be hidden.'}
        $t=[double]$row.latency_ms
        if(-not [double]::IsFinite($t) -or $t -lt 0){throw 'Invalid HTTP latency.'}
        $latencies+=$t;if($row.cache_hit){$hits++};if($t -lt 100){$under++}
    }
    $sorted=@($latencies|Sort-Object)
    foreach($entry in @(@('p50_ms',.50),@('p95_ms',.95),@('p99_ms',.99),@('max_ms',1.0))){
        $value=$sorted[[int][Math]::Ceiling($entry[1]*$rows.Count)-1]
        if([Math]::Abs([double]$m[$entry[0]]-$value) -gt 1e-9){throw "HTTP percentile is not traceable: $($entry[0])"}
    }
    $expectedHits=if($Plan.parameters.cache -eq 'warm'){$rows.Count}else{0}
    if($hits -ne $expectedHits -or $hits -ne $m.cache_hits){throw 'Raw HTTP cache mismatch.'}
    if($raw.elapsed_seconds -le 0 -or [Math]::Abs($m.throughput_total-$rows.Count/$raw.elapsed_seconds) -gt 1e-6 -or [Math]::Abs($m.throughput_success-$m.throughput_total) -gt 1e-6 -or [Math]::Abs($m.proportion_under_100_ms-$under/$rows.Count) -gt 1e-12){throw 'Invalid HTTP throughput/proportion.'}
}
