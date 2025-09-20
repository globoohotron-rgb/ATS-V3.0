# Формати повідомлень (Message Envelope)
Обовʼязкові поля:
- **task_id** `T-YYYYMMDD-XXX`
- **from** / **to**
- **phase** `draft|run|gate|report`
- **status** `PENDING|RUNNING|DONE|FAIL|BLOCKED`
- **attempt** (1..2)
- **timestamp_utc** (ISO-8601)
- **payload_ref** (шлях/URI до основного артефакту)
- **artifacts** (список шляхів)
- **metrics** (ключові числа)
- **notes** (≤3 буліти)
- **signature** (хеш/версії для відтворюваності)

Толеранси: порядок ключів неважливий; переноси/пробіли — не причина перевипуску; числові розбіжності ±2% ок, якщо не в Acceptance.

Повʼязані: [Ролі](roles.md), [Ворота](gates.md).
<!-- >> ORDERS-LOG FORMAT -->
## Order logs

File: runs/YYYY-MM-DD/run-*/orders.log.csv
Schema: timestamp,symbol,side,qty,price,reason,risk_state
Purpose: unified order log for paper/live executor; used by G3/G4.
<!-- << ORDERS-LOG FORMAT -->
