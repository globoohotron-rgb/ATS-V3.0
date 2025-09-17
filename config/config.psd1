@{
  General = @{
    CostBps = 5
    Seed    = 42
  }
  Model = @{
    Fast = 10
    Slow = 20
    Grid = @(
      @{ f = 5;  s = 20 },
      @{ f = 8;  s = 21 },
      @{ f = 10; s = 20 },
      @{ f = 10; s = 30 },
      @{ f = 12; s = 26 },
      @{ f = 15; s = 40 }
    )
  }
  RnD = @{
    MaxFolds  = 4
    IS_Ratio  = 0.60
    OOS_Ratio = 0.10
    Step_Ratio= 0.10
  }
  Risk = @{
    G3 = @{ DailyLossLimit = 0.02; MaxDD = 0.05 }
    G6 = @{ DailyLossLimit = 0.02; KillSwitchMaxDD = 0.08; CrashReturn = -0.10; StreamBars = 60 }
  }
  Guardrails = @{
    SearchMax     = 8
    ISSharpeHalf  = 0.5
    DDBufferPP    = 2.0
    VsBH_PPMargin = 2.0
  }
}
