# Data Formats (v1)

## prices (CSV)
- Path: data/raw/*prices*.csv
- Columns:
  - timestamp (datetime, UTC, required, sorted)
  - symbol (string, required)
  - open/high/low/close (number ≥0, required)
  - volume (number ≥0, optional)
- PK: (timestamp, symbol)
- Frequency: 1m|5m|1h|1d
- Gaps: not allowed

## calendar (CSV)
- Path: data/raw/*calendar*.csv
- Columns:
  - date (date, required, sorted)
  - is_open (boolean, required)
- PK: (date)
- Frequency: 1d
- Gaps: not allowed
