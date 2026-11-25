# Wierdr

- Прежде чем менять код, прочитай нужное из `docs/` — там уже записано то, что иначе
  приходится выяснять заново. Оглавление по файлам — [`docs/README.md`](docs/README.md):
  [`architecture/`](docs/architecture/) — устройство по файлам и типам;
  [`tradeoffs/`](docs/tradeoffs/) — решения и их причины (схема ввода, жесты, раскладка);
  [`features/`](docs/features/) — что реализовано;
  [`BUILD.md`](docs/BUILD.md) — сборка, установка, устройства, симуляторы, WDA;
  [`live-activity.md`](docs/live-activity.md) — Live Activity и APNs, проверенные ловушки;
  [`relay.md`](docs/relay.md) — релей пушей (Cloudflare Worker в `Relay/`, App Attest, права), развёртывание;
  [`site.md`](docs/site.md) — лендинг `wierdr.workat.dev` (`Site/`, Workers со статикой): картинки, выкладка;
  [`wierdrd.md`](docs/wierdrd.md) — демон на Mac: формула Homebrew (тап `wierdbytes/apps`), установка из приложения, выпуск;
  [`host-setup.md`](docs/host-setup.md) — лист «Set Up <хост>»: демон и интеграции агентов (pi, Claude Code, Codex) из приложения;
  [`app-store.md`](docs/app-store.md) — план публикации в App Store;
  [`claude-code.md`](docs/claude-code.md) — мод `cc` для Claude Code (метки `agent.*`, лимиты), проверенные ловушки;
  [`codex.md`](docs/codex.md) — плагин `codex` для Codex CLI (метки `agent.*`, лимиты, `--no-daemon`), проверенные ловушки;
  [`pi.md`](docs/pi.md) — расширение pi `@wierdbytes/pi-wierdr` (`Integrations/pi`: метки `agent.*`, лимиты, bash, сабагенты), выпуск в npm;
  [`ssh.md`](docs/ssh.md), [`hc-protocol-client.md`](docs/hc-protocol-client.md) — связь с herdr-core;
  [`Integrations/herdr-app`](Integrations/herdr-app/README.md) — раскладка `wierdr` и моды `wierdr-sidebar`, `wierdr-tabs`, `wierdr-pane`
  для Herdr на Mac (сайдбар Wierdr на десктопе): правка здесь, затем `sh Integrations/herdr-app/install.sh`;
  копии в `~/.config/herdr-app` руками не править, в chezmoi их нет.
  Меняя поведение или решение, обнови соответствующий документ в том же коммите.
- Документы читай выборочно: файл — по оглавлению, в файле — `grep -n '^#' <файл>`, потом нужный
  раздел через `offset`/`limit`; целиком — только когда нужен весь. Размер смотри в байтах
  (`wc -c`), не в строках.
- Пиши документы так же: один файл — одна тема, до ~15 KB; у каждой темы свой заголовок;
  строки до 100 знаков, без таблиц с длинными ячейками. Разросся — раздели; новый файл —
  строка в `docs/README.md`.
- Перед тем как назвать UI-изменение готовым, проверь его на физическом iPad:
  [`scripts/ipad.sh`](scripts/ipad.sh); изменения раскладки iPhone (`App/Sources/Phone`) — на
  iPhone: [`scripts/iphone.sh`](scripts/iphone.sh). Инструкция в шапке
  [`scripts/device.sh`](scripts/device.sh). iPhone — личный телефон: прежде чем тапать,
  печатать или переустанавливать, посмотри `shot`, и если на нём работают — спроси.
- Push в `master` с поднятой версией в `Integrations/pi/package.json` публикует `@wierdbytes/pi-wierdr` в npm
  ([`publish-pi.yml`](.github/workflows/publish-pi.yml)) — push только с разрешения.
  Выпуск и тесты — [`docs/pi.md`](docs/pi.md).
- Push в `master` с поднятой версией в `Packages/WierdrKit/Sources/wierdrd/Version.swift` выпускает
  wierdrd: релиз на GitHub и коммит формулы в тап `wierdbytes/homebrew-apps` от CI
  ([`release-wierdrd.yml`](.github/workflows/release-wierdrd.yml)) — push только с разрешения.
  Формулу в тапе руками не править: её пишет `scripts/wierdrd-release.sh`. Выпуск —
  [`docs/wierdrd.md`](docs/wierdrd.md).
- Herdr на Mac (эталон для сравнения, снимки через `herdr-app shot`):
  [`~/.config/herdr-app/AGENTS.md`](~/.config/herdr-app/AGENTS.md).
