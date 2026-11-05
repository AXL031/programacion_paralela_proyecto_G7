# Benchmarking workflow

The performance campaign starts only after the environment and inputs are recorded. The first step is a preflight:

```powershell
./scripts/download-data.ps1
./scripts/benchmark-preflight.ps1
```

The preflight checks the Docker Linux engine, Compose configuration, project service state, pinned source checksums, and hashes of the demo and training configurations. It records the current commit, branch, worktree state, host/engine capacity, and input identities in the ignored local file `data/benchmark-preflight.json`. It does not start containers, change the demo dataset, train a model, or measure performance. A missing source file or mismatched checksum is an explicit failure.

Run it from a clean, committed checkout before each campaign. Do not start measurements while the project demo services are running. The report is preparation evidence only; it is not a benchmark result.

Planned follow-up parts:

1. Compare loader runs with one and four local workers using fresh, isolated storage and verify identical counts and snapshot checksums.
2. Compare sequential training with distributed training using one, two, and four workers, with repeated runs and numerical-equivalence checks.
3. Measure API latency, throughput, errors, cache states, and process/container resources under declared concurrency.
4. Consolidate repeatable results, speedup/efficiency, limitations, and any changes justified by the measurements.

Each later part must preserve raw run metadata, state the measurement scope, and avoid treating a functional check or a single timing as a benchmark.
