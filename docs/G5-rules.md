# G5-rules.md


# >> G5-RULES START
# G5 — Правила та пороги

**Guardrails (OOS, для фінального вердикту G5):**
- Грід параметрів ≤ 8
- OOS PnL: якщо IS > 0 → ≥ 25% від IS; інакше → ≥ 0
- OOS Sharpe: ≥ 0 та (якщо IS > 0) ≥ 0.5×IS Sharpe
- OOS MaxDD: ≤ 1.5× IS MaxDD + 2 п.п.
- Порівняння з Buy&Hold (OOS): PnL ≥ BH − 2 п.п.

## Формат рішення
Вердикт: **ACCEPT** або **REJECT** + коротке «чому» + лінки на HTML-звіт і EvidencePack.
# << G5-RULES END
