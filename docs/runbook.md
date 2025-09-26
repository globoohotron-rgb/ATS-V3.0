<!-- ATS RUNBOOK (managed) START -->
# Runbook — Cleanups & Housekeeping

**Останнє оновлення:** 2025-09-26 21:31:49

## Політика карантину `attic/`
- Ми **не видаляємо** нічого одразу. Усе спірне — в `attic/` на 14 днів «тиші».
- Через 14 днів — повторний огляд і лише тоді фінальне видалення (за потреби).

## Retention
- `runs/` — тримаємо **7 днів**, серед старших залишаємо 1 «exemplar».
- `reports/` — **14 днів**.
- `digests/`, `logs/` — **30 днів**.

## Data мінімізація
- `data/raw/` — **1–2 тижні** (дефолт: 14 днів), старше → `attic/data-raw-archive/`.
- `data/processed/` — **останні 2 дні**, старше → `attic/data-processed-archive/`.

## Scripts
- Канонічні в корені: `day.ps1`, `dash.ps1`, `week.ps1`, `run.ps1`, `QC_case.ps1`.
- Усе з суфіксами `bak|backup|copy|old|tmp|targeted|precise|test` у `scripts/` → `attic/scripts-legacy/` (за маніфестом).

## Tests
- Лишаємо стандартні дерева: `unit|integration|e2e|smoke|fixtures|helpers|mocks|stubs|resources`.
- Тестові файли формату `*.Tests.ps1|*.Test.ps1|*.Spec.ps1` залишаємо.
- Legacy-патерни `old|legacy|bak|tmp|wip|draft|sandbox|experimental` → `attic/tests-legacy/` (за маніфестом).

## .gitignore (керований блок)
- Ігноруємо сміття/виводи (`*.log`, `*.tmp|*.bak|*.old|*.orig`, `runs/`, `digests/`, `logs/`, `artifacts/`, `data/raw/`, `data/processed/`).
- **Не** ігноруємо `attic/` — комітимо як історію карантину.

## Як відкотити
1. Знайди відповідний маніфест у `attic/**/manifest*.json` або `*-apply*.json`.
2. Перемісти потрібний елемент назад (або `git restore` із тега-знімка `audit-YYYYMMDD-before-clean`).
3. Перезапусти перевірки.

— _Цей блок керується інструментом чистки. Редагуй поза маркерами або змінюй політики в скриптах чистки._
<!-- ATS RUNBOOK (managed) END -->

