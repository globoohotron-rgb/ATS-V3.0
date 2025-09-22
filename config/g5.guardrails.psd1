@{
  Schema = 'G5.Guardrails/v1'
  Thresholds = @{
    GridMax                  = 8
    PnL_OOS_vs_IS_Ratio      = 0.25     # якщо IS PnL > 0 → OOS PnL ≥ 25% від IS
    PnL_OOS_MinIfISNonPos    = 0.0      # якщо IS PnL ≤ 0 → OOS PnL ≥ 0
    Sharpe_OOS_Min           = 0.0
    Sharpe_OOS_vs_IS_Ratio   = 0.5      # якщо IS Sharpe > 0 → OOS Sharpe ≥ 0.5×IS
    MaxDD_OOS_vs_IS_Mult     = 1.5
    MaxDD_OOS_vs_IS_Add      = 0.02     # +2 п.п.
    OOS_vs_BH_PnL_MinDiff    = -0.02    # OOS PnL ≥ BH − 2 п.п.
  }
}