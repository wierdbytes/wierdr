# Codex в Wierdr и herdr

Codex CLI в терминале herdr-core показывается в Wierdr так же, как pi и Claude Code: статус
в строке агента, вторая строка `6.1 Sol @high · 41k`, счётчик саб‑агентов, лимиты подписки
ChatGPT в сайдбаре. Для этого две части:

- **сам Codex** (без плагинов) шлёт свой статус по OSC 7501;
- **плагин `codex`** из этого репозитория ([`Integrations/codex`](../Integrations/codex/README.md))
  пишет метки `agent.*` на свой терминал и лимиты в документ `limits` — то же, что
  `@wierdbytes/pi-herdr` делает для pi и мод `cc` ([claude-code.md](claude-code.md)) для
  Claude Code, с теми же ключами и тем же документом.

В Wierdr для плагина ничего не меняется: метки читает `AgentLabels.meta` в
`TerminalFacts.swift` (доверяет им, только пока `agent.pid` = foreground pid), документ —
`Limits.swift`.

## Что откуда

| Что | Откуда | Где в herdr-core |
|---|---|---|
| Статус `idle` / `working` / `done` | Codex сам, OSC 7501 (`app: "codex"`; только state/app/kind, без `msg`) | `status` терминала |
| Заголовок `<спиннер> <имя треда> \| <проект>`, пока Codex ждёт ответа — `[ ! ] Action Required \| …` | Codex сам (OSC title) | `title` |
| Модель, провайдер, effort, контекст, окно, сессия, число саб‑агентов, pid | плагин `codex` | метки `agent.*` |
| Лимиты подписки ChatGPT (5 часов, 7 дней, другие семейства) | плагин `codex` (и pi-herdr для pi) | документ `limits` |

Чего Codex сам не даёт: `msg`, записей (`records`) для саб‑агентов (они работают внутри
процесса Codex, без своего терминала), модели и лимитов. Имя треда Codex придумывает сам
(`$CODEX_HOME/session_index.jsonl`, `{"id","thread_name"}`), оно видно в заголовке. Счётчик
`turn` у терминала растёт на каждом ходе и на каждом блокирующем экране — уже окно
«Hooks need review» до первого промпта даёт `turn` 1.

Метки (все строки, только у интерактивного Codex и только в терминале herdr-core):
`agent.app` = `codex`, `agent.pid` = pid TUI Codex (= foreground pid терминала),
`agent.model` = `GPT-6.1 Sol` (имя в стиле pi из `GPT-6.1-Sol` / `gpt-6.1-sol`; Wierdr под
знаком openai сокращает до `6.1 Sol`), `agent.model_id`, `agent.provider` (`model_provider`
сессии, обычно `openai`), `agent.effort` (нет при `none`), `agent.ctx` / `agent.ctx_max`,
`agent.session` (`codex resume <id>`), `agent.subagents`. Меток кэша нет: OpenAI не сообщает
время жизни кэша. Таблица с примерами — в [README плагина](../Integrations/codex/README.md#labels).

## Как это работает

Расширять Codex изнутри процесса нельзя. Точка расширения — командные хуки, их приносит
плагин: `.codex-plugin/plugin.json` и `hooks/hooks.json` в формате Codex. Каждый хук —
`python3 "$PLUGIN_ROOT/hooks/herdr.py" <событие>` (только стандартная библиотека; без
`python3` или вне терминала herdr-core команда сразу выходит с 0). Codex запускает хук как
`$SHELL -lc "<команда>"` в новой сессии (setsid, без tty): cwd — cwd сессии, окружение — снимок
окружения процесса Codex плюс `PLUGIN_ROOT` / `PLUGIN_DATA`. В тексте команды Codex
подставляет только `${PLUGIN_ROOT}` с фигурными скобками; плагин пишет `"$PLUGIN_ROOT"`, и
переменную в кавычках раскрывает shell. Stdout хуков `SessionStart` и `UserPromptSubmit`
становится контекстом модели, поэтому `herdr.py` ничего не печатает и всегда выходит с 0.

Хуки и что они пишут:

- **`SessionStart`** (синхронный) — все метки, все ключи (пустые удаляют оставшееся от
  прошлого агента). Срабатывает лениво, **на первом промпте**, а не при запуске; на
  `/clear`, `/resume`, форке — с новым id сессии.
- **`UserPromptSubmit`** (async) — модель, effort, окно, сессия: так виден `/model` между
  ходами.
- **`PostModelRequest`** (async) — `agent.ctx` из `token_usage.total_tokens` ответа; лимиты не
  чаще раза в 30 с. С `agent_id` (запрос саб‑агента) — отметить саб‑агента работающим.
- **`PostCompact`** (async) — контекст после сжатия (Codex сам пересчитывает и пишет
  `token_count` до этого хука).
- **`SubagentStart`** / **`SubagentStop`** (async), **`PostToolUse`** с matcher
  `(close|resume)_agent$` (async) — `agent.subagents`.
- **`Stop`** (async) — всё заново и лимиты.
- **`SessionEnd`** (таймаут 3 с, это максимум) — снять все свои метки.

Ни один хук не несёт effort, окно контекста и лимиты, поэтому плагин читает **rollout**
сессии (`transcript_path`, `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-…-<thread>.jsonl`) с
конца, кусками по 64 КБ (не больше 8 МБ):
`turn_context` {model, effort}; `event_msg` `thread_settings_applied`
{thread_settings{model, reasoning_effort}} — `/model` между ходами; `task_started`
{model_context_window}; `token_count` {info{last_token_usage.total_tokens,
model_context_window}, rate_limits{limit_id, primary, secondary, plan_type,
rate_limit_reached_type}}. Первая строка — `session_meta` (`source`: `cli` у встроенного
TUI, `vscode` у app-server, `exec`, у саб‑агента — объект `subagent`). Без effort в
rollout — `default_reasoning_level` модели из `$CODEX_HOME/models_cache.json`; без окна —
`context_window × effective_context_window_percent` оттуда же.

Запись — прямо в сокет `HC_TERMINAL_SOCKET` (JSON‑RPC строками, как pi-herdr; одно
соединение на запуск хука, несколько запросов): `terminal.get` (foreground pid и текущие
метки), `terminal.label` (шлются только изменения), `doc.get` / `doc.set`.

**Чей это хук.** Метки пишутся, только если foreground pid терминала — один из ближайших
(до 4) предков процесса хука, **и между ними нет `codex app-server`**, и сессия интерактивная
(`session_meta.source` ∈ `cli`, `vscode`). Иначе меток нет, но лимиты пишутся (они от
терминала не зависят). Хуки саб‑агентов приносят rollout саб‑агента (его `source` —
`subagent`), поэтому они меняют только `agent.subagents` и только когда метки сессии уже на
терминале (`agent.app`, `agent.pid`, `agent.session` совпадают).

**Саб‑агенты.** Они работают внутри процесса Codex. Плагин хранит в `$PLUGIN_DATA` на сессию
множества ходов каждого агента: `SubagentStart` и `PostModelRequest` с `agent_id` отмечают
ход (`turn_id`) активным, `SubagentStop` — законченным; агент считается, пока у него есть
активный незаконченный ход и база Codex
(`$CODEX_HOME/state_5.sqlite`, `thread_spawn_edges`, только чтение) не числит его `closed`.
Открытые рёбра сами по себе не годятся: Codex закрывает агента только по `close_agent`, а
модели часто оставляют его открытым и простаивающим.

**Лимиты.** Из последних `token_count` (по одному на `limit_id`, внутри последнего хода)
собирается чтение: семейство `codex` — окна `5h` / `7d` (`window_minutes` 300 / 10080),
другие — `<limit_id>.<окно>` с подписью `<limit_name> <окно>`, как у pi-herdr; ≥ 100 % —
`exhausted`. Свёртка — правила pi-herdr (CAS: `doc.get` → свёртка → `doc.set` с версией, до 5
попыток при конфликте; в одном окне `used` только растёт; более позднее окно заменяет).
`at` — время строки в rollout. Уже записанное чтение повторно не пишется. Ключ аккаунта —
первые 8 hex sha256 от `tokens.account_id` из `$CODEX_HOME/auth.json` (запасные: claim
`https://api.openai.com/auth` → `chatgpt_account_id` в id‑токене, `creator_account_id` из
`session_meta`). Проверено: `codex.d4800446` — тот же ключ, что у pi-herdr. `label` — e‑mail
из id‑токена, `plan` — `plan_type`, `source` — `codex`, `host` — `gethostname()`. Токены
не читаются дальше этого и никуда не пишутся. `codex exec` и саб‑агенты пишут лимиты, но не
метки.

## Установка

```
codex plugin marketplace add wierdbytes/wierdr
codex plugin add codex@wierdr
```

(или в TUI `/plugins`). Маркетплейс — [`.agents/plugins/marketplace.json`](../.agents/plugins/marketplace.json)
в корне (`wierdr`, плагин `codex` из `./Integrations/codex`). Codex ищет маркетплейс в
`.agents/plugins/marketplace.json` раньше `.claude-plugin/marketplace.json` (первый найденный
выигрывает), поэтому Claude Code и Codex берут из одного репозитория разные маркетплейсы.
Имена плагинов в Codex не зарезервированы (только имена маркетплейсов). `codex plugin add`
**копирует** плагин в `~/.codex/plugins/cache/wierdr/codex/<version>/`; данные хуков — в
`~/.codex/plugins/data/codex-wierdr/` (`PLUGIN_DATA`).

Хуки нужно один раз **доверить**: при следующем запуске Codex показывает «Hooks need
review» (Review hooks → `t` на каждом хуке `codex@wierdr`, или «Trust all»). Доверие
хранится в `~/.codex/config.toml` (`[hooks.state."codex@wierdr:hooks/hooks.json:<event>:0:0"]`
`trusted_hash` / `trusted_content_hash`) и в `~/.codex/.hook-trust/<sha256>`. Хеш содержимого
плагина закреплён, поэтому **после каждого обновления плагина Codex спрашивает снова**.
`__pycache__` в хеш не входит, но `herdr.py` всё равно не пишет байткод в копию плагина.

## Проверенные ловушки

- **Демон app-server.** Обычный `codex` (0.167+) запускает или переиспользует общий
  `codex app-server` (один на `CODEX_HOME`; ставится в
  `~/.codex/packages/app-server-daemon/…`, у 0.170 CLI он был 0.167). Демон крутит модель,
  инструменты и хуки с окружением терминала, который его запустил: у хуков второго терминала
  был `HC_TERMINAL_ID` первого, а `SessionEnd` приходит только при остановке демона.
  Проверено на 0.170: **родитель демона — TUI того терминала, что его запустил** (ppid =
  foreground pid), так что одной проверки «foreground — предок хука» мало; нужна и проверка
  «между ними нет `app-server`». С ней в режиме демона хуки отработали
  (`not the foreground's hook`), меток нет, лимиты записаны. С `--no-daemon` (или любым
  `-c key=value`, кроме булевых `features.*`) Codex встроенный: TUI = foreground pid, хуки —
  его дети, `HC_TERMINAL_ID` свой. Поэтому в README — алиас
  `[ -n "$HC_TERMINAL_ID" ] && alias codex='codex --no-daemon'`; лаунчеры herdr и Wierdr уже
  запускают `codex --no-daemon`. Остановить демон: `codex app-server daemon stop`
  (процесс `app-server daemon pid-update-loop` остаётся — его убить).
- **Порядок `PostModelRequest` и `token_count`.** Если в ответе вызов инструмента, строка
  `token_count` попадает в rollout только после выполнения инструментов (проверено: хук на
  44,3 с, `token_count` на 48,4 с при `sleep 4`). Без инструментов async‑хук стартует
  (~150 мс), когда строка уже есть. Поэтому `agent.ctx` берётся из хука, а значение
  запоминается в `PLUGIN_DATA`: `Stop` / `PostCompact` берут rollout, только если его строка
  новее.
- **`SubagentStop` и последний `PostModelRequest` саб‑агента** стартуют почти одновременно и
  в любом порядке (видели 2 мс разницы, наоборот), поэтому учёт — по `turn_id`, а не по
  времени.
- **Foreground pid во время shell‑команд остаётся TUI** (проверено `sleep 4`: каждые 0,6 с
  `foreground.pid` = pid Codex), Wierdr метки не отбрасывает.
- **`hc send <t> "/exit"` не выполняет команду**: hc оборачивает вставку в
  `<hc from=…>…</hc>`, и Codex получает сообщение. Команды — клавишами: `hc keys <t> / e x i t`,
  затем `hc keys <t> enter`.
- **Модель не всегда зовёт саб‑агента**: «Spawn one sub-agent…» gpt-6-luna выполнил сам;
  сработало явное «Use the spawn_agent tool … then wait_agent … then close_agent». `close_agent`
  она всё равно не вызвала — ребро осталось `open`.
- **`codex delete <id>`** без терминала требует `--force`.
- Запуск 0.167 предлагает обновиться (Update now / Skip) — выбирать Skip.

## Как проверить вживую

Настоящие агенты работают в том же herdr-core, поэтому — отдельные терминалы
`wierdrtest-codex-*`, отдельный документ лимитов, `gpt-6-luna` на `low`. Перед этим —
копия `~/.codex/config.toml` (установка и доверие пишут туда).

```sh
cp -p ~/.codex/config.toml /tmp/config.toml.bak; shasum -a 256 ~/.codex/config.toml
codex plugin marketplace add ~/me/dev/wierdr && codex plugin add codex@wierdr
mkdir -p /tmp/wierdrtest-codex && cd /tmp/wierdrtest-codex
hc run --bg --no-parent --name wierdrtest-codex-1 -- env WIERDR_CODEX_LIMITS_DOC=wierdrtest-codex-limits \
  WIERDR_CODEX_DEBUG=1 codex --no-daemon -m gpt-6-luna -c model_reasoning_effort=\"low\"
hc read wierdrtest-codex-1               # «Hooks need review» → hc keys … enter / t / esc
hc send wierdrtest-codex-1 "Reply with exactly: ok"; hc wait wierdrtest-codex-1
hc get wierdrtest-codex-1 --json         # labels, foreground.pid, status, title, turn
tail ~/.codex/plugins/data/codex-wierdr/debug.log
printf '{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"wierdrtest-codex-limits"}}\n' | hc connect
hc keys wierdrtest-codex-1 / e x i t; hc keys wierdrtest-codex-1 enter   # метки должны исчезнуть
```

Уборка: `hc rm` каждого `wierdrtest-codex-*`; документ — `doc.set` с `value: null` и текущей
версией; треды — `codex delete --force <id>` (и саб‑агентов); `codex plugin remove
codex@wierdr`, `codex plugin marketplace remove wierdr`, удалить
`~/.codex/plugins/{cache/wierdr,data/codex-wierdr}` и свой файл в `~/.codex/.hook-trust/`;
вернуть `config.toml` из копии и сверить контрольную сумму; демон, если запускался, —
`codex app-server daemon stop` и `kill` оставшегося `pid-update-loop`.

Что видно на 0.170.0 (2026‑11‑18, gpt-6-luna, подписка Plus, `--no-daemon`): до первого
промпта меток нет; на первом промпте (`SessionStart` и `UserPromptSubmit`) — `agent.app`
`codex`, `agent.pid` (= `foreground.pid`), `agent.model` `GPT-6 Luna`, `agent.model_id`
`gpt-6-luna`, `agent.provider` `openai`, `agent.effort` `low`, `agent.ctx_max` `258400`,
`agent.session`; после ответа — `agent.ctx` `15671`; с саб‑агентом — `agent.subagents` `1`.
Что метка пропадает с концом хода саб‑агента, проверено только тестами: живой прогон
показал гонку `SubagentStop` / `PostModelRequest`, и учёт по `turn_id` появился уже после
него.
В `wierdrtest-codex-limits` — `codex.d4800446` (label — e‑mail аккаунта, `plan` `plus`,
`5h` и `7d`). После `/exit` меток нет. 0.167.0 (`--no-daemon`) — то же самое: async‑хуки,
`PostModelRequest`, `SubagentStart/Stop`, `SessionEnd`. Хуки отрабатывают за 80–250 мс.
Режим демона (0.170 CLI, демон 0.167) — меток нет, лимиты есть.

Тесты без сессии: `python3 -m unittest discover -s Integrations/codex/tests` (чистые функции и
хуки как отдельные процессы против поддельного сокета herdr-core).
