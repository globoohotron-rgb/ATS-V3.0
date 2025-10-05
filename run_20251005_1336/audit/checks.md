- config : FOUND
- docs : FOUND
- ops : MISSING

# Gate Contract Status
- G0 : FOUND
- G1 : FOUND
- G2 : FOUND
- G3 : FOUND
- G4 : FOUND
- G5 : FOUND
- G6 : FOUND
- G7 : FOUND

# G0 Status
- threshold.max_missing_pct : MISSING
- threshold.max_dupe_pct : MISSING
- threshold.max_gap_pct : MISSING
- G0 decision : NEEDS_THRESHOLD

# G1 Status
- datasets.manifest : FOUND
- features.manifest : FOUND
- features.tests : FOUND
- threshold.max_missing_pct : MISSING
- threshold.min_variance : MISSING
- threshold.max_pearson_abs : MISSING
- threshold.drift_window : FOUND
- threshold.psi_max : MISSING
- G1 decision : NEEDS_THRESHOLD

# G1 Hotfix
- Status : FAILED
- Library : scripts/g1_lib.ps1
- Parser : OK
- Smoke tests : FAILED
- Artifacts : G1\fix_report.md, G1\smoke_tests.json

# G2 Status
- config.model.manifest : FOUND
- config.model.grid : FOUND
- config.training.split : FOUND
- datasets.manifest : FOUND
- features.manifest : FOUND
- grid.limit : OK
- threshold.is_sharpe_min : MISSING
- threshold.max_turnover : MISSING
- threshold.min_trades : MISSING
- G2 decision : REJECT

# G2 Status
- config.model.manifest : FOUND
- config.model.grid : FOUND
- config.training.split : FOUND
- grid.limit : OK
- threshold.is_sharpe_min : MISSING
- threshold.max_turnover : MISSING
- threshold.min_trades : MISSING
- candidates.count : 4
- G2 decision : NEEDS_THRESHOLD

# G3 Status
- config.costs.manifest : FOUND
- config.risk.limits : FOUND
- G2.selected : FOUND
- Decision : PASS
- Reasons : NEEDS_DATA/FEATURES: synthetic examples used
- Artifacts : G3\g3_metrics.json, G3\costs_breakdown.csv, G3\g3_report.md

# G4 Status
- config.sim.engine : FOUND
- config.sim.rules  : FOUND
- G2.selected       : FOUND
- threshold.fill_rate_min     : MISSING
- threshold.max_slippage_bps_p95     : MISSING
- threshold.max_rejects_pct     : MISSING
- threshold.latency_ms_p95     : MISSING
- Decision          : NEEDS_THRESHOLD
- Reasons           : OK
- Artifacts         : G4\orders.csv, G4\fills.csv, G4\g4_metrics.json, G4\g4_report.md

# G4 Status
- config.sim.engine : FOUND
- config.sim.rules  : FOUND
- G2.selected       : FOUND
- Decision          : REJECT
- Artifacts         : G4\orders.csv, G4\fills.csv, G4\g4_metrics.json, G4\g4_report.md

# G4 Status
- config.sim.engine : FOUND
- config.sim.rules  : FOUND
- Decision          : NEEDS_THRESHOLD
- Artifacts         : G4\orders.csv, G4\fills.csv, G4\g4_metrics.json, G4\g4_report.md

# G3 Status
- g3_report.md      : FOUND
- g3_metrics.json   : FOUND
- costs.manifest.yml: FOUND
- risk.limits.yml   : FOUND
- Decision          : PASS
- Reasons           : OK

# G4 Status
- orders.csv        : FOUND
- fills.csv         : FOUND
- g4_metrics.json   : FOUND
- g4_report.md      : FOUND
- G2.selected.yml   : FOUND
- Decision          : NEEDS_THRESHOLD
- Reasons           : NEEDS_THRESHOLD:fill_rate_min,max_slippage_bps_p95,max_rejects_pct,latency_ms_p95
- Artifacts         : G3\g3_findings.md, G4\g4_findings.md, audit_summary.md

# G5 Status
- G2.selected.yml   : FOUND
- datasets.manifest : FOUND
- features.manifest : FOUND
- training.split    : FOUND
- Decision          : REJECT
- Sharpe_OOS        : NA
- IS→OOS ratio      : 0
- Edge_vs_BH        : 0
- Artifacts         : G5\oos_metrics.json, G5\bh_metrics.json, G5\wfo_table.csv, G5\wfo_summary.json, G5\g5_report.md

# G6 Status
- safety.kill.yml    : MISSING
- risk.limits.yml    : FOUND
- sim.engine.yml     : FOUND
- sim.rules.yml      : FOUND
- G2.selected.yml    : FOUND
- G4.g4_metrics.json : FOUND
- Decision           : REJECT
- Triggers fired     : 0
- Artifacts          : G6\stress_inputs.json, G6\triggers.csv, G6\g6_report.md

# G7 Status
- Overall Decision   : REJECT
- PASS               : 1
- REJECT             : 3
- NEEDS_THRESHOLD    : 3
- EvidencePack       : EvidencePack.zip
