# Wierdr — что реализовано

Wierdr (`pw.xff.wierdr`) — нативное приложение для iPad и iPhone (SwiftUI + UIKit там, где нужен
терминал), которое подключается к **herdr-core** на Mac по SSH и показывает тот же мир,
что десктопный Herdr: спейсы, табы, сплиты, агентов и их живые терминалы. Внешний вид
сайдбара и терминальной панели перенесён с твоего сетапа (`wierd-layout`: `wierd-chrome`,
`wierd-agents`, `wierd-tabs`, `wierd-pane`, `agent-counts`) без панели лимитов.

Скриншоты: `docs/screenshots/` (`ipad-*` — демо‑режим, `terminal-*` — терминал,
`iphone-*` — iPhone, см. [iphone.md](iphone.md)).

## Архитектура (кратко)

`Packages/WierdrKit` — всё, кроме UI (общее для iPad и iPhone):
`HerdrCore` (протокол herdr-core: фреймы, JSON‑RPC, attach‑стримы, события, документы),
`HerdrSSH` (SSH‑транспорт, ключи, known hosts), `WierdrModel` (живая модель + команды,
`WorkspaceEngine`), `wierdr-cli` (отладка на Mac: `wierdr-cli ws`, `ls`, `doc`, `events`, `attach`),
`WierdrActivity` / `WierdrPush` / `wierdrd` (Live Activity агентов, [iphone.md](iphone.md); демон — [wierdrd.md](../wierdrd.md)).
`App/Sources` — SwiftUI. Подробно: `docs/architecture/`, `docs/hc-protocol-client.md`,
`docs/ssh.md`. Тесты: `make test` (unit), `WIERDR_LIVE=1` / `WIERDR_SSH_LIVE=1` — живые.
