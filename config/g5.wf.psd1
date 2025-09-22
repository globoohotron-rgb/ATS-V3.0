@{
  Schema         = 'G5.WF/v1'
  DefaultProfile = 'std'
  Profiles       = @{
    std = @{
      Name      = 'std'
      Align     = 'MonthStart'
      TrainBars = 756
      OOSBars   = 21
      StepBars  = 21
      Neighbors = 1
      MinSample = @{
        BarsIS     = 504
        BarsOOS    = 21
        TradesIS   = 100
        TradesOOS  = 10
      }
    }
    compact = @{
      Name      = 'compact'
      Align     = 'MonthStart'
      TrainBars = 504
      OOSBars   = 21
      StepBars  = 21
      Neighbors = 1
      MinSample = @{
        BarsIS     = 252
        BarsOOS    = 21
        TradesIS   = 50
        TradesOOS  = 5
      }
    }
    demo = @{
      Name      = 'demo'
      Align     = 'None'     # для короткої історії вирівнювання не критичне
      TrainBars = 120
      OOSBars   = 20
      StepBars  = 20
      Neighbors = 1
      MinSample = @{
        BarsIS     = 60
        BarsOOS    = 20
        TradesIS   = 10
        TradesOOS  = 3
      }
    }
  }
}