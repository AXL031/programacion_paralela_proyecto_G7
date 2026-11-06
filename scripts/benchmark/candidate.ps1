# Dot-sourced by common.psm1; keeps the authoritative reference tied to the campaign.
function Assert-BenchCandidateReference($Context,$Plan,$Result,$Diagnostics){
    $m=$Result.metrics; $d=$Diagnostics
    foreach($key in @('reference_diagnostics_path','reference_diagnostics_sha256','run_id','reference_model_path','reference_model_sha256','published_weights')){
        if(-not $m.Contains($key)){throw "Missing reference identity: $key"}
    }
    $referencePath=Resolve-BenchPath (Resolve-BenchPath $m.reference_diagnostics_path) $Context.raw_dir
    if($referencePath -ne (Join-Path $Context.raw_dir 'reference/sequential-diagnostics.json')){throw 'Reference is not the frozen campaign sequential diagnostic.'}
    if((Get-FileHash -LiteralPath $referencePath).Hash.ToLowerInvariant() -cne $m.reference_diagnostics_sha256){throw 'Reference diagnostics checksum mismatch.'}
    $r=Read-BenchJson $referencePath
    $modelPath=Resolve-BenchPath (Resolve-BenchPath $m.reference_model_path) $Context.raw_dir
    if($modelPath -ne (Join-Path $Context.raw_dir 'reference/published-model.json') -or (Get-FileHash -LiteralPath $modelPath).Hash.ToLowerInvariant() -cne $m.reference_model_sha256){throw 'Published reference model identity/checksum mismatch.'}
    $model=Read-BenchJson $modelPath
    if($model.dataset_id -cne $Result.dataset.id -or $model.snapshot_sha256 -cne $Result.dataset.snapshot_sha256 -or $model.weights.Count -ne $m.published_weights.Count){throw 'Published reference model dataset/dimensions mismatch.'}
    for($j=0;$j -lt $model.weights.Count;$j++){
        $a=[double]$model.weights[$j];$b=[double]$m.published_weights[$j]
        $limit=$Context.config.protocol.absolute_tolerance+$Context.config.protocol.relative_tolerance*[Math]::Max([Math]::Abs($a),[Math]::Abs($b))
        if(-not [double]::IsFinite($b) -or [Math]::Abs($a-$b) -gt $limit){throw 'Published model differs from sequential reference.'}
    }
    foreach($x in @($r,$d)){
        foreach($key in @('schema_version','mode','run_id','reference_run_id','reference_mode','dataset_id','snapshot_sha256','encoder_sha256','encoder_version','seed','config','train_examples','validation_examples','test_examples','dimension','total_steps','candidate_weights','reference_weights','absolute_tolerance','relative_tolerance','equivalent')){
            if(-not $x.Contains($key)){throw "Incomplete candidate diagnostic: $key"}
        }
        if($x.schema_version -cne 'candidate-diagnostics-v1' -or $x.dataset_id -cne $Result.dataset.id -or $x.snapshot_sha256 -cne $Result.dataset.snapshot_sha256){throw 'Candidate dataset/schema/snapshot mismatch.'}
        if(-not $x.equivalent -or $x.absolute_tolerance -ne $Context.config.protocol.absolute_tolerance -or $x.relative_tolerance -ne $Context.config.protocol.relative_tolerance){throw 'Candidate tolerance/equivalence mismatch.'}
        if($x.dimension -lt 1 -or $x.candidate_weights.Count -ne $x.dimension -or $x.reference_weights.Count -ne $x.dimension){throw 'Invalid candidate dimensions.'}
    }
    if($r.mode -cne 'sequential' -or $r.reference_mode -cne 'sequential' -or $r.run_id -cne $r.reference_run_id){throw 'Campaign reference must be sequential.'}
    if($d.mode -cne $Plan.parameters.mode -or $d.run_id -cne $m.run_id -or $d.reference_mode -cne 'sequential'){throw 'Candidate mode/run/reference mismatch.'}
    if($d.mode -eq 'distributed'){
        if($d.run_id -ceq $r.run_id -or $d.run_id -ceq $d.reference_run_id -or $d.reference_run_id -cne $r.run_id){throw 'Distributed self-reference or unrelated reference run.'}
    }elseif($d.reference_run_id -cne $d.run_id){throw 'Sequential diagnostic is not self-validated.'}
    foreach($key in @('encoder_sha256','encoder_version','seed','train_examples','validation_examples','test_examples','dimension','total_steps')){
        if($d[$key] -cne $r[$key]){throw "Reference differs: $key"}
    }
    $frozen=Read-BenchJson (Resolve-BenchPath $Context.config.inputs.training)
    foreach($key in @('epochs','batch_size','learning_rate','l2','seed','task_timeout_seconds')){
        if($d.config[$key] -ne $r.config[$key] -or $d.config[$key] -ne $frozen[$key]){throw "Training configuration mismatch: $key"}
    }
    if($d.config.workers -ne $Plan.parameters.workers){throw 'Diagnostic worker configuration mismatch.'}
    for($i=0;$i -lt $r.dimension;$i++){
        $a=[double]$r.candidate_weights[$i]; $b=[double]$d.candidate_weights[$i]
        $limit=$Context.config.protocol.absolute_tolerance+$Context.config.protocol.relative_tolerance*[Math]::Max([Math]::Abs($a),[Math]::Abs($b))
        if(-not [double]::IsFinite($a) -or -not [double]::IsFinite($b) -or [Math]::Abs($a-$b) -gt $limit){throw 'Candidate differs from actual sequential reference.'}
        $expected=if($d.mode -eq 'sequential'){$b}else{$a}
        if([double]$d.reference_weights[$i] -ne $expected){throw 'Embedded reference weights do not match the referenced diagnostic.'}
    }
}
