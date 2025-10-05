# G6 Kill-Switch Audit Report

## Kill-Switch Config Check
kill.yml: MISSING
limits.yml: FOUND
engine.yml: FOUND
rules.yml: FOUND
G2 selected.yml: FOUND
G4 g4_metrics.json: FOUND

## Stress Results
Triggers file: triggers.csv
Triggers fired: 0

## Thresholds & Decision
G6 = REJECT
Reasons:
- SAFETY_MISSING: kill.yml

## EvidencePack
See: 
stress_inputs.json
, 
triggers.csv
