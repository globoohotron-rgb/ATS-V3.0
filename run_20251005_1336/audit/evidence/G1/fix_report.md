# G1 Hotfix Report

## Parser
Status: OK

## Smoke Tests
Status: FAILED

## Functions
- Ema(vals, alpha) -> [double[]] (null-safe, rounded 6)
- ZScore(vals) -> [double[]] (mean/std via [math]::Sqrt)
- Diff(vals) -> [double[]] (prev-aware, null-safe)
- Lag(vals, k) -> [object[]] (first k nulls)
- ToDate(v) -> [datetime[]] (try/catch, null on bad parse)
