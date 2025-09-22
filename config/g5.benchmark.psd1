@{
  Schema         = 'G5.Benchmark/v1'
  DefaultProfile = 'SPY'
  Profiles = @{
    SPY = @{
      Name        = 'SPY'
      Symbol      = 'SPY'        # змінюй під свій дата-фід
      Provider    = 'local'      # довідково
      Field       = 'Close'
      Currency    = 'USD'
      ReturnMode  = 'CloseToClose' # обчислення PnL BH
      ReinvestDiv = $true
    }
    BTC = @{
      Name        = 'BTCUSD'
      Symbol      = 'BTCUSD'
      Provider    = 'local'
      Field       = 'Close'
      Currency    = 'USD'
      ReturnMode  = 'CloseToClose'
      ReinvestDiv = $false
    }
  }
}