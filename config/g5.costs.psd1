@{
  Schema         = 'G5.Costs/v1'
  DefaultProfile = 'vanilla'
  Profiles = @{
    vanilla = @{
      Name               = 'vanilla'
      SlippageBps        = 5     # 0.05% на угоду (дві сторони сумарно)
      SpreadBps          = 0     # якщо моделюємо half-spread окремо — вкажи тут
      CommissionPerTrade = 0.0   # фікс за угоду (у валюті акаунта)
      BorrowAnnualBps    = 0     # вартість шорту річна, б.п. (за замовч. 0)
      PnLDiscountBps     = 10    # консервативний дисконт на OOS (5–10 б.п.)
      Apply              = 'per_trade' # політика застосування (довідкова)
    }
    conservative = @{
      Name               = 'conservative'
      SlippageBps        = 10
      SpreadBps          = 3
      CommissionPerTrade = 0.0
      BorrowAnnualBps    = 50
      PnLDiscountBps     = 15
      Apply              = 'per_trade'
    }
  }
}