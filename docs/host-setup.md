# Настройка хоста из приложения

После первого подключения к хосту Wierdr проверяет, что на компьютере есть всё, что ему
помогает, и предлагает поставить недостающее:

- **ключ устройства** вместо пароля — после каждого входа по паролю;
- **демон** `wierdrd` — Live Activity агентов ([wierdrd.md](wierdrd.md));
- **интеграции** в установленные и поддерживаемые харнессы агентов — модель, effort,
  контекст, сабагенты и лимиты подписок: pi-wierdr в pi ([pi.md](pi.md)), `cc@wierdr` в
  Claude Code ([claude-code.md](claude-code.md)), `codex@wierdr` в Codex
  ([codex.md](codex.md)).

Код: `WierdrModel/Daemon.swift`, `WierdrModel/Integrations.swift` (пробы, выводы, скрипты;
тесты `DaemonTests`, `IntegrationsTests`), `App/Sources/Setup/` (состояние сессии, строки,
лист, когда его показать).

## Что видит человек

**Лист «Set Up <хост>»** открывается:

- **после каждого входа по паролю** — сразу, не дожидаясь проб. Пароль приложение не
  хранит и спрашивает при каждом подключении ([ssh.md](ssh.md#authentication));
- **один раз на хост** — когда обе пробы первого подключения закончились, если что‑то
  просит человека: демон не установлен, остановлен или устарел (или нет Homebrew), или в
  найденном харнессе нет интеграции либо она выключена. Флаг — `setup.checked.<id хоста>`
  в UserDefaults, удаляется вместе с хостом.

За одно подключение лист открывается не больше одного раза: закрытый до конца проб, он
не открывается снова. Автоматические переподключения сессии его не открывают. Во время
тура лист не показывается. В DEBUG `-setup-offer always` показывает его при каждом
подключении.

В листе секции:

- **Sign In** (только после входа по паролю) — «Signs In With: Password» и кнопка
  *Install This iPhone's Key* (`AppModel.installKeyAndSwitch`: ключ дописывается в
  `~/.ssh/authorized_keys` через `machine.exec`, хост переключается на ключ). После
  установки строка — «✓ This iPhone's Key». Та же кнопка есть в Settings → Connection.

- **Daemon** — состояние wierdrd и кнопка: *Install with Homebrew*, *Start wierdrd* или
  *Update wierdrd* ([wierdrd.md](wierdrd.md#как-приложение-проверяет-и-ставит)).
- **Agent Integrations** — строка на каждый найденный харнесс: имя, версия, интеграция,
  состояние и кнопка *Install …* или *Enable …*. Не найдено ни одного — так и написано.

Под каждой секцией — команды, которые выполнят её кнопки. Кнопка «Not Now», пока что‑то
предложено, потом «Done». Пока идёт установка, лист не смахивается.

**Settings** держит те же строки: секции **Daemon** (и на iPhone строка Live Activity) и
**Agent Integrations**, на iPad и на iPhone. При открытии Settings пробы повторяются.

## Интеграции

| Харнесс | Нужна версия | Установлена ли | Установка |
|---|---|---|---|
| pi | ≥ 1.5.0 (peer dependencies pi-wierdr) | `pi list` содержит `npm:@wierdbytes/pi-wierdr` | `pi install npm:@wierdbytes/pi-wierdr`, затем `pi remove` старых `pi-herdr` и `pi-agents`, если стоят |
| Claude Code | ≥ 2.1.304 (mods API, [claude-code.md](claude-code.md#как-это-работает)) | `claude plugin list --json`: есть `cc@wierdr`, `enabled` | `claude plugin marketplace add wierdbytes/wierdr` (если маркетплейса `wierdr` нет), `claude plugin install cc@wierdr`; выключенный — `claude plugin enable cc@wierdr` |
| Codex | ≥ 0.167.0 и python3 | `$CODEX_HOME/config.toml` (`[plugins."codex@wierdr"]`, не `enabled = false`) и кэш `plugins/cache/wierdr/codex` | `codex plugin marketplace add wierdbytes/wierdr` (если маркетплейса `wierdr` нет), `codex plugin add codex@wierdr` |

Выводы (`Integrations.Found.verdict`):

- харнесс старше нужного — «Too old» и просьба обновить его, кнопки нет;
- у Codex нет python3 — «Needs python3», совет поставить Command Line Tools;
- нет интеграции — *Install*; выключена в Claude Code — *Enable*; выключена в Codex —
  *Install* (`codex plugin add` включает её снова);
- есть — «Installed».

После установки строка говорит, как интеграция начнёт работать:

- **pi** — новые сессии, в идущей `/reload`;
- **Claude Code** — новые сессии, в идущей `/reload-plugins`;
- **Codex** — первый запущенный Codex попросит доверить хуки (*Trust all*), идущие нужно
  перезапустить.

Пока в `config.toml` нет доверия хукам `codex@wierdr`, строка напоминает о нём же.
Доверить хуки за человека приложение не может: это решение Codex, и хеш закреплён за
содержимым плагина.

Харнесс, которого нет, в листе не показывается: ставить сам харнесс приложение не
предлагает.

## Как идут пробы и установки

Всё через `machine.exec` ядра (`/bin/sh`), как у демона.

**PATH.** Харнессы стоят там, куда их кладут их установщики: pi — в `~/.bun/bin`, Claude
Code и Codex — в `~/.local/bin`, Homebrew, npm, mise. Эти папки добавляют rc‑файлы
оболочки, а у ядра свой `PATH`. Поэтому скрипт сначала спрашивает `PATH` у логин‑оболочки
человека (`Integrations.loginPath`):

- `$SHELL -lic` — zsh, bash, sh, dash, ksh и fish;
- ответ — строка с меткой `wierdr-path:`, так что то, что печатают rc‑файлы, не мешает;
- на ответ 10 с, потом оболочка убивается;
- после её `PATH` идут обычные папки.

`exec` выполняет одну команду, поэтому алиасы и функции оболочки не нужны: харнессы —
программы.

**Проба** (`Integrations.probeBody`, до 60 с; на mentoair 2 с) печатает строки
`<харнесс>.<ключ>=<значение>` и `done=1`: путь, версию (первое число с точками из
`--version`), состояние, старые пакеты pi, доверены ли хуки Codex, есть ли python3. Список
Codex (`codex plugin list`) не годится: он тянет удалённый каталог, больше минуты. Поэтому
состояние Codex читается из его `config.toml` и кэша плагинов. На macOS `/usr/bin/python3` —
заглушка: без Command Line Tools она не запускается, а показывает окно установки на экране
Mac. Поэтому проба её не запускает, а проверяет `xcode-select -p`.

**Установка** (`Integrations.script(for:)`, до 300 с): `set -e`, stdin закрыт, команды
самого харнесса. Маркетплейс с именем `wierdr`, который уже есть (с GitHub или из
локальной копии репозитория, как на mentoair), остаётся как есть. После установки —
проба: интеграции нет — ошибка с концом вывода.

## Проверено

- Команды установки всех трёх — без вопросов, неинтерактивно: в Homebrew‑окружении
  mentoair, в чистых папках конфигурации. Повторные `marketplace add` у Claude Code и Codex
  ничего не ломают. Проверено 2026‑11‑19: pi 1.5.2, Claude Code 2.1.319, Codex 0.170.0.
- `WIERDR_INTEGRATIONS_LIVE=1 swift test --filter IntegrationsTests` ставит настоящие
  интеграции в одноразовые `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `PI_CODING_AGENT_DIR` и проверяет
  пробой, что они встали. Конфигурация Mac при этом не трогается.
- Вход по паролю (симулятор iPhone, `scripts/test-pwsshd.sh`, ядро mentoair): запрос
  пароля, неверный пароль → «Couldn't connect» → Retry → снова запрос; верный → лист с
  Sign In сверху, *Install This iPhone's Key* → «✓ This iPhone's Key» (строку из
  `~/.ssh/authorized_keys` потом убрали).
- Через приложение (симулятор iPhone, test sshd, ядро mentoair): лист со всеми тремя
  «Installed»; `cc@wierdr`, выключенный руками, — «Disabled», *Enable cc@wierdr*, снова
  «Installed» и подсказка про `/reload-plugins`.

## Проверенные ловушки

- `codex plugin list` тянет удалённый каталог: больше минуты.
- `pi remove` пакета, которого нет, выходит с 1. Поэтому старые пакеты pi убираются, только
  если `pi list` их показывает.
- bash сообщает «Terminated» о фоновом задании, убитом TERM, даже в неинтерактивном
  `sh`. Сторож логин‑оболочки убирается сигналом PIPE: о нём bash молчит.
