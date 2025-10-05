| ID | Name | DoD | Thresholds | Artifacts | Kill Switch |
|----|------|-----|------------|-----------|-------------|
| G0 | Data Integrity | дірки, зсуви, аномалії | grid_max=8; seed=1337 | EvidencePack |  |
| G1 | Feature Stability | стабільність фіч | grid_max=8; seed=1337 | EvidencePack |  |
| G2 | Seed/Grid | фікс seed, грід ≤8 | grid_max=8; seed=1337 | EvidencePack |  |
| G3 | Risk/Costs | витрати, ліміти ризику | grid_max=8; seed=1337 | EvidencePack |  |
| G4 | Simulator Rules | симулятор, правила виконання | grid_max=8; seed=1337 | EvidencePack |  |
| G5 | OOS Walk-Forward | walk-forward OOS, sanity vs buy&hold | maxdd_limit=TODO; grid_max=8; is_to_oos_ratio_min=>=0.5; oos_sharpe_min=TODO; seed=1337 | EvidencePack |  |
| G6 | Kill Switch | kill-switch правила | grid_max=8; seed=1337 | EvidencePack | ENABLED |
| G7 | Reporting | збір звіту, артефакти, EvidencePack | grid_max=8; seed=1337 | EvidencePack |  |
