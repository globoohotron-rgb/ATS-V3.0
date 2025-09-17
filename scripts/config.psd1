@{
  Seed       = 42
  TxCostBps  = 8     # 8 bps default
  Risk       = @{
    DailyLimit   = -0.02  # -2% day limit
    KillSwitchDD = -0.08  # -8% equity drawdown
  }
}