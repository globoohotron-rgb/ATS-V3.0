# G0 Data Audit Report
| Dataset | Exists | Rows | Cols | Missing% | Dupe% | Gap% | Anom | Invalids | Leakage | Decision |
|---------|--------|------|------|----------|-------|------|------|----------|---------|----------|
| sample_ds | False | 0 | 0 | 0 | 0 | 0 | 0 | 0 | False | NEEDS_THRESHOLD |

> Thresholds missing/TODO for: max_missing_pct, max_dupe_pct, max_gap_pct

Artifacts (EvidencePack) per dataset are stored under: C:\Volodymyr\ATS v3.0\run_20251005_1336\audit\G0

PASS/REJECT logic: if any defined threshold is exceeded or leakage detected, G0 = REJECT.
