@{
    General = @{
        Seed = 42
        Mode = 'dev'   # dev|paper|live
    }

    WalkForward = @{
        TrainDays = 252
        OOSDays   = 63
        Windows   = 4
        GridMax   = 8
    }

    Costs = @{
        TxCostsBps  = 10
        SlippageBps = 5
    }

    Risk = @{
        DailyLimit = -0.02
        MaxDD      = 0.08
    }

    Benchmarks = @{
        BHBufferPp = 2
    }

    Paths = @{
        DataRaw   = 'data/raw'
        Processed = 'data/processed'
        Reports   = 'reports'
        Runs      = 'runs'
    }
}
