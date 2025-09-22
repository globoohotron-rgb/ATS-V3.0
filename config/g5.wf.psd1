@{
  Schema         = 'G5.WF/v1'
  DefaultProfile = 'std'
  Profiles       = @{
    std = @{
      Name      = 'std'
      Align     = 'MonthStart'    # вирівнюємо на початок місяця
      TrainBars = 756             # ≈ 3 роки (252*3)
      OOSBars   = 21              # ≈ 1 місяць
      StepBars  = 21              # крок WF (rolling)
      Neighbors = 1               # перевіряти ±1 сусіднє налаштування (стабільність поруч)
      MinSample = @{
        BarsIS     = 504          # ≥ 2 роки для тренування
        BarsOOS    = 21           # ≥ 1 місяць для OOS
        TradesIS   = 100          # мін. кількість угод у IS (якщо застосовно)
        TradesOOS  = 10           # мін. кількість угод у OOS (якщо застосовно)
      }
    }
    compact = @{
      Name      = 'compact'
      Align     = 'MonthStart'
      TrainBars = 504             # ≈ 2 роки
      OOSBars   = 21
      StepBars  = 21
      Neighbors = 1
      MinSample = @{
        BarsIS     = 252          # ≥ 1 рік
        BarsOOS    = 21
        TradesIS   = 50
        TradesOOS  = 5
      }
    }
  }
}