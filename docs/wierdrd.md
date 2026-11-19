# wierdrd

Демон Wierdr на Mac (до 2026‑11‑19 — `wierdr-push`). Сейчас он ведёт Live Activity агентов
([live-activity.md](live-activity.md)): строит сводку из ядра и шлёт пуши через релей
([relay.md](relay.md)) или прямо в APNs. Другие функции демона придут сюда же.

Код: `Packages/WierdrKit/Sources/wierdrd` (CLI, версия в `Version.swift`), логика —
`WierdrPush`; проверка и установка из приложения — `WierdrModel/Daemon.swift` и
`App/Sources/Setup/` ([host-setup.md](host-setup.md)).

## Установка

**Из приложения.** После первого подключения к хосту Wierdr проверяет wierdrd. Если он не
установлен, остановлен или устарел, лист «Set Up <хост>» ([host-setup.md](host-setup.md))
предлагает кнопку: *Install with Homebrew*, *Start wierdrd* или *Update wierdrd*. Под
кнопкой — команды, которые она выполнит. То же есть в **Settings → Daemon**, на iPad и на
iPhone.

**Руками:**

```sh
brew install wierdbytes/apps/wierdrd
brew services start wierdrd
```

Тап `wierdbytes/apps` — репозиторий
[`wierdbytes/homebrew-apps`](https://github.com/wierdbytes/homebrew-apps): там только
`Formula/wierdrd.rb`, его пишет workflow выпуска. Бинарь лежит в релизах Wierdr
(`wierdrd-v<версия>`).

Без `~/.config/wierdr/push.json` демон шлёт пуши через релей Wierdr; `push.json` нужен
только для своего ключа APNs ([live-activity.md](live-activity.md#настройка-один-раз)).

| Что | Где |
|---|---|
| Бинарь и его ресурсы (`WierdrKit_WierdrModel.bundle`: `programs.json`) | `$(brew --prefix)/opt/wierdrd/libexec/` |
| Команда `wierdrd` | `$(brew --prefix)/bin/wierdrd` — скрипт `exec` на бинарь в `libexec` |
| Служба | launchd `sh.brew.wierdrd`, `~/Library/LaunchAgents/sh.brew.wierdrd.plist`: `wierdrd run`, KeepAlive, при входе |
| Журнал | `$(brew --prefix)/var/log/wierdrd.log` |
| Конфиг, состояние, ключ печати | `~/.config/wierdr/` (`push.json`, `push-state.json`, `seal-key`) |

Команды: `wierdrd status` (конфиг, ключ печати, устройства, каналы, активность, сводка),
`wierdrd reset` (закончить активность, удалить каналы), `wierdrd --version`.
Обновить руками: `brew upgrade wierdrd && brew services restart wierdrd`.

Только macOS 15 и новее (arm64 и x86_64). Демон ищет `hc` в `PATH`, `~/.local/bin`,
`/opt/homebrew/bin`, `/usr/local/bin`.

## Как приложение проверяет и ставит

Всё идёт через `machine.exec` ядра (`Daemon.probe`, `Daemon.perform`), а не отдельной
командой по SSH. Команда выполняется в сессии самого herdr‑core: на Mac это обычно Aqua,
потому что ядро запущено из графической сессии. Поэтому `brew services` кладёт службу в
`gui/<uid>`, как при обычном входе. Из SSH‑сессии Homebrew взял бы `user/<uid>`.

**Проба** (`Daemon.probeScript`, `/bin/sh`, 20 с). Печатает строки `ключ=значение`:

- `uname -s`;
- `brew` — в `PATH`, `/opt/homebrew`, `/usr/local`, Linuxbrew;
- `wierdrd` — в `PATH`, `<prefix>/bin`, `~/.local/bin` — и его `--version`;
- поставлен ли он формулой (`<prefix>/opt/wierdrd`);
- работает ли (`pgrep -x wierdrd`);
- если не работает — последний код выхода службы (`sh.brew.wierdrd`, в старом Homebrew
  `homebrew.mxcl.wierdrd`) и последняя строка её журнала.

Что из этого следует (`Daemon.Status.verdict`):

| Проба | Приложение |
|---|---|
| Работает | «Running · 0.1.0» |
| Работает, но старше `Daemon.minimumVersion` и из формулы | Update |
| Не установлен, Homebrew есть | Install with Homebrew |
| Не установлен, Homebrew нет | Объясняет: поставить Homebrew с brew.sh, потом Check Again |
| Из формулы, не работает | Start (после падения — код выхода и строка журнала) |
| Установлен не формулой (сборка из исходников) и не работает | Объясняет, где он; кнопки нет |
| Не macOS | «Not available» |

**Действия** (`Daemon.script(for:)`, до 600 с — предел `machine.exec`). Homebrew
запускается без вопросов, без автообновления, подсказок и чистки:

- **Install:** `brew tap wierdbytes/apps`, `brew trust --tap` (если в Homebrew есть `trust`),
  `brew install wierdbytes/apps/wierdrd`, `brew services restart wierdrd`;
- **Start:** `brew services restart wierdrd`;
- **Update:** тап, `git pull` только этого тапа (`brew update` обновлял бы все и падал бы с
  любым из них), `brew upgrade`, `brew services restart`.

После действия приложение проверяет ещё раз, до 5 с, пока служба не поднимется. Не
поднялась — показывает код выхода и строку журнала.

Когда показывается лист и что ещё в нём (интеграции агентов) — [host-setup.md](host-setup.md).
Ради демона лист не показывается, если тот работает, если хост не Mac и если стоит сборка
из исходников.

**Settings → Daemon** (`DaemonSection`): состояние и та же кнопка, на iPhone — строка
Live Activity (зарегистрирован ли телефон в ядре). Проба повторяется при каждом
подключении и при открытии Settings.

## Выпуск

Версия — `Packages/WierdrKit/Sources/wierdrd/Version.swift`. Push в `master` с поднятой
версией запускает `.github/workflows/release-wierdrd.yml` (**push только с разрешения**):

1. тесты `WierdrPushTests` и `DaemonTests`;
2. сборка arm64 + x86_64 (`scripts/wierdrd-release.sh package`);
3. подпись Developer ID и нотаризация, если заданы секреты;
4. релиз `wierdrd-v<версия>` в этом репозитории с `wierdrd-<версия>-macos.tar.gz`;
5. коммит `Formula/wierdrd.rb` (ссылка и SHA‑256) в тап `wierdbytes/homebrew-apps` от
   `github-actions[bot]`. Пишет он deploy key тапа с правом записи: закрытая половина — секрет
   `HOMEBREW_APPS_DEPLOY_KEY` здесь, открытая — в Settings → Deploy keys тапа. Права на
   остальные репозитории у этого ключа нет.

Если такой релиз уже есть, workflow ничего не делает. Запуск руками — `workflow_dispatch`.
Формулу шаблон держит `scripts/wierdrd-release.sh formula`: правки в тапе руками
перезапишет следующий выпуск.

Секреты подписи (необязательные, имена как у autosk):

- `APPLE_CERTIFICATE` — base64 `.p12` с сертификатом Developer ID Application и ключом;
- `APPLE_CERTIFICATE_PASSWORD`;
- `APPLE_SIGNING_IDENTITY`.

Для нотаризации ещё ключ App Store Connect API: `APPLE_API_KEY` (id), `APPLE_API_ISSUER`,
`APPLE_API_KEY_P8` (base64 `.p8`). Без секретов бинарь остаётся с ad‑hoc подписью
линковщика и работает: загрузки формул Homebrew в карантин не ставит.

Приложение предлагает Update демонам старше `Daemon.minimumVersion`
(`WierdrModel/Daemon.swift`). Его поднимают, когда приложению нужно новое от демона, и
только после того, как такой демон выпущен.

**Проверить формулу до выпуска** — через локальный тап:

```sh
SHA=$(scripts/wierdrd-release.sh package)
T=/tmp/wierdr-localtap; mkdir -p $T/Formula
scripts/wierdrd-release.sh formula "$SHA" "file://$PWD/dist/wierdrd-$(scripts/wierdrd-release.sh version)-macos.tar.gz" > $T/Formula/wierdrd.rb
(cd $T && git init -q && git add . && git commit -qm test)
brew tap wierdrtest/local $T && brew install wierdrtest/local/wierdrd
# потом: brew uninstall wierdrd && brew untap wierdrtest/local
```

## Разработка

`scripts/wierdrd.sh install` собирает демон из исходников и ставит его LaunchAgent
`pw.xff.wierdr.wierdrd` (`~/.local/share/wierdrd`, ссылка в `~/.local/bin`, журнал
`~/Library/Logs/wierdrd.log`). Заодно он:

- останавливает службу Homebrew: на Mac должен работать один демон, иначе два процесса
  пишут один `push-state.json`;
- убирает агент прежнего `wierdr-push` (`pw.xff.wierdr.push`).

Вернуться к Homebrew: `scripts/wierdrd.sh uninstall && brew services start wierdrd`.
Приложение считает работающим любой процесс `wierdrd`, откуда бы он ни был.

## Переименование из `wierdr-push`

Новые имена получили программа, её служба, журнал и скрипт. Остались прежними:

- документы ядра `wierdr-push` (регистрация телефонов) и `wierdr-push-seal` (ключ печати) —
  это контракт данных между приложением и демоном;
- модуль `WierdrPush`;
- файлы в `~/.config/wierdr/`: демон под новым именем продолжает ту же активность с теми
  же каналами.

Старый агент (`~/Library/LaunchAgents/pw.xff.wierdr.push.plist`) убирает
`scripts/wierdrd.sh install` или руками: `launchctl bootout gui/$(id -u)/pw.xff.wierdr.push`
и удалить plist.

## Проверенные ловушки

- Homebrew 7 отвергает формулу, где `depends_on :macos` стоит вместе с
  `depends_on macos: :sequoia`. Минимальная версия идёт внутрь `on_macos do … end`.
- Служба Homebrew теперь называется `sh.brew.<формула>`, раньше — `homebrew.mxcl.<формула>`.
  Проба смотрит оба имени.
- Загрузку формулы Homebrew в карантин не ставит: на скачанном бинаре только
  `com.apple.provenance`, ad‑hoc подпись запускается (проверено 2026‑11‑19, macOS 27,
  Homebrew 7.0.14).
- `brew install <user>/<tap>/<формула>` в Homebrew 6+ сам доверяет формуле
  (`==> Trusted formula …`); тап остаётся недоверенным, пока нет `brew trust --tap`.
- Swift 6.4 собирает в `.build/out/Products/Release`, а не в `.build/release`. Путь даёт
  `swift build … --show-bin-path`.
- `swift build --arch arm64 --arch x86_64` кладёт рядом с бинарём ресурсные бандлы
  (`WierdrKit_WierdrModel.bundle`, `swift-crypto_Crypto.bundle`). `Bundle.module` ищет их
  возле исполняемого файла, поэтому бинарь лежит в `libexec` вместе с ними, а в `bin` —
  скрипт с `exec`.
- Пробу и действия запускает ядро (`machine.exec`), его `PATH` — тот, с которым ядро
  стартовало. Поэтому скрипты сами ищут `brew` в известных местах.

## Что осталось

- Подпись Developer ID и нотаризация: нужны секреты в репозитории
  ([app-store.md](app-store.md), п. 3).
- Без Homebrew приложение только объясняет, что делать. Возможный следующий шаг —
  ставить бинарь из релиза напрямую, с LaunchAgent как у `scripts/wierdrd.sh`.
- herdr‑core бывает и на Linux; wierdrd — только macOS.
