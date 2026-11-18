# Wierdr

- Прежде чем менять код, прочитай нужное из `docs/` — там уже записано то, что иначе
  приходится выяснять заново:
  [`architecture.md`](docs/architecture.md) — устройство по файлам и типам;
  [`TRADEOFFS.md`](docs/TRADEOFFS.md) — решения и их причины (схема ввода, жесты, раскладка);
  [`FEATURES.md`](docs/FEATURES.md) — что реализовано;
  [`BUILD.md`](docs/BUILD.md) — сборка, установка, устройства, симуляторы, WDA;
  [`live-activity.md`](docs/live-activity.md) — Live Activity и APNs, проверенные ловушки;
  [`claude-code.md`](docs/claude-code.md) — мод `cc` для Claude Code (метки `agent.*`, лимиты), проверенные ловушки;
  [`ssh.md`](docs/ssh.md), [`hc-protocol-client.md`](docs/hc-protocol-client.md) — связь с herdr-core.
  Меняя поведение или решение, обнови соответствующий документ в том же коммите.
- Перед тем как назвать UI-изменение готовым, проверь его на физическом iPad:
  [`scripts/ipad.sh`](scripts/ipad.sh); изменения раскладки iPhone (`App/Sources/Phone`) — на
  iPhone: [`scripts/iphone.sh`](scripts/iphone.sh). Инструкция в шапке
  [`scripts/device.sh`](scripts/device.sh). iPhone — личный телефон: прежде чем тапать,
  печатать или переустанавливать, посмотри `shot`, и если на нём работают — спроси.
- Herdr на Mac (эталон для сравнения, снимки через `herdr-app shot`):
  [`~/.config/herdr-app/AGENTS.md`](~/.config/herdr-app/AGENTS.md).
