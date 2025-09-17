# Ролі та межі відповідальності

## A-шар (фабрика)
- **Commander** — формує денну ціль (TaskSpec), пріоритизує, вирішує BLOCKED.
- **Engineer** — виробляє/править код, повертає артефакти + інструкцію відтворення.
- **Supervisor** — запускає Gate, вердикт PASS/FAIL за чек-листом.
- **Accountant** — облік артефактів, оновлення state, денний підсумок (ResultSpec).

## B-шар (ATS)
- **Data Bot** — ingest OHLCV → parquet, контроль якості.
- **Signal Bot** — SMA/EMA/RSI, інтерфейс сигналів, батч-розрахунок.
- **Risk Bot** — позиціон-сайзинг, стоп/тейк, денні ліміти.
- **Executor Bot** — ордери (paper→live), анти-дублювання.
- **Monitor/Backtest/Reporter** — PnL/Sharpe/MaxDD, equity-curve, HTML-звіти.
- **Research/Optimizer** — грід/байєс/генетика, walk-forward, анти-оверфіт.

> Межі: кожен бот повертає reproducible артефакт + коротке резюме; ніхто не змінює чужі артефакти без TaskSpec.

Пов’язані документи: [Формати](formats.md), [Ворота](gates.md).
