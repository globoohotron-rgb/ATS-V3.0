@{
  Executor = @{
    Mode = 'paper'
  }
  General = @{
    CostBps = 5
    Seed = 42
  }
  Guardrails = @{
    DDBufferPP = 2
    ISSharpeHalf = 0.5
    SearchMax = 8
    VsBH_PPMargin = 2
  }
  Model = @{
    Fast = 10
    Grid = @(
      @{
        f = 5
        s = 20
      }
      @{
        f = 8
        s = 21
      }
      @{
        f = 10
        s = 20
      }
      @{
        f = 10
        s = 30
      }
      @{
        f = 12
        s = 26
      }
      @{
        f = 15
        s = 40
      }
    )
    Slow = 20
  }
  Risk = @{
    DayLimitPct = -2
    G3 = @{
      DailyLossLimit = 0.02
      MaxDD = 0.05
    }
    G6 = @{
      CrashReturn = -0.1
      DailyLossLimit = 0.02
      KillSwitchMaxDD = 0.08
      StreamBars = 60
    }
    KillSwitchPct = 8
    MaxDDPct = 5
  }
  RnD = @{
    IS_Ratio = 0.6
    MaxFolds = 4
    OOS_Ratio = 0.1
    Step_Ratio = 0.1
  }
}
