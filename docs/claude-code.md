# Claude Code в Wierdr и herdr

Claude Code в терминале herdr-core показывается в Wierdr так же, как pi: статус в строке
агента, вторая строка `Opus 5.5 @high · 228k`, кольцо кэша, счётчик саб‑агентов, лимиты
подписки в сайдбаре. Для этого две части:

- **сам Claude Code** (без плагинов) шлёт свой статус по OSC 7501;
- **мод `cc`** из этого репозитория ([`Integrations/claude-code`](../Integrations/claude-code/README.md))
  пишет метки `agent.*` на свой терминал и лимиты подписки в документ `limits` — то же,
  что для pi делает `@wierdbytes/pi-herdr`, с теми же ключами и тем же документом.

В Wierdr для мода ничего не меняется: он читает метки (`AgentLabels.meta` в
`TerminalFacts.swift`) и документ (`Limits.swift`) одинаково, кто бы их ни записал.

## Что откуда

| Что | Откуда | Где в herdr-core |
|---|---|---|
| Статус `idle` / `working` / `blocked` / `done` / `error`, `msg` | Claude Code сам, OSC 7501 (`app: "claude-code"`) | `status` терминала |
| Фоновые саб‑агенты и фоновые шеллы (по записи на каждый, с заголовком) | Claude Code сам, OSC 7501 | `records` терминала |
| Модель, провайдер, effort, контекст, окно, сессия, кэш, число саб‑агентов, pid | мод `cc` | метки `agent.*` |
| Лимиты подписки (5 часов, 7 дней) | мод `cc` (и pi-herdr для pi) | документ `limits` |

Метки (все строки, только у интерактивного Claude и только в терминале herdr-core):
`agent.app` = `claude-code`, `agent.pid` = pid Claude, `agent.model` =
`Claude Opus 5.5` (имя в стиле pi из `claude-opus-5-5`; Wierdr под знаком anthropic
сокращает до `Opus 5.5`), `agent.model_id`, `agent.provider` (`anthropic`, либо
`amazon-bedrock` / `google-vertex` / `azure-foundry` по `CLAUDE_CODE_USE_*`), `agent.effort`,
`agent.ctx` / `agent.ctx_max`, `agent.session` (`claude --resume <id>`),
`agent.cache_until` / `agent.cache_ttl`, `agent.subagents`. Таблица с примерами — в
[README мода](../Integrations/claude-code/README.md#labels).

## Как это работает

Мод — это плагин Claude Code с хуками (mods API; моду нужен Claude Code ≥ 2.1.304 из‑за
`$.settings.read({ key })`, вживую проверен на 2.1.327 и на 2.1.319 — старт и выход):
модуль `hooks/register.ts` экспортирует `register(on)` и подписывается на события.

- **`session.start`** — один раз на загрузку. Если нет `HC_TERMINAL_ID` /
  `HC_TERMINAL_SOCKET`, мод ничего не делает. Иначе читает id сессии, модель, usage, pid
  Claude (родитель `/bin/sh -c 'echo $PPID'`, запущенного через `$.process.run`), effort
  из `CLAUDE_CODE_EFFORT_LEVEL` или настройки `effortLevel` и пишет все метки до первого
  промпта (первая запись шлёт все ключи, пустые удаляют то, что осталось от прошлого Claude).
- **`turn.step`** основного цикла (без `agentId`): в момент отправки запроса — модель,
  effort запроса и продление кэша; по ответу — контекст (`input + cache_read +
  cache_creation`) и время жизни кэша. Шаги саб‑агентов только пересчитывают
  `agent.subagents`.
- **`turn.complete`**, **`session.measure`**, любая команда (`command.run`: `/model`,
  `/effort`, `/clear`…) — перечитать сессию; `session.measure` даёт и контекст.
- **`agent.spawn`** (кроме `e.resume`) — пересчитать саб‑агентов и опрашивать
  `$.agent.list()` каждые 5 с, пока кто‑то `pending` / `running` / `waiting`.
- **`session.end`**: при выходе (`prompt_input_exit`, `logout`, `other`) — снять все метки в
  пределах общих 1,5 с; при `clear` / `resume` — оставить метки (без мигания), сбросить
  контекст и кэш и через полсекунды записать новый id сессии.

Запись — через `hc connect`: модулю хуков нельзя сокеты, но можно
`$.process.run(['hc', 'connect'], { stdin })`; `hc connect` читает одну строку JSON‑RPC,
отвечает одной строкой и выходит по EOF. Методы те же, что у pi-herdr: `terminal.label`,
`doc.get`, `doc.set`. `HC_SOCKET` выставляется в `HC_TERMINAL_SOCKET`, чтобы попасть в ядро
своего терминала (сам `hc` смотрит на `HC_SOCKET` / `HC_SESSION`, не на
`HC_TERMINAL_SOCKET`). Изменения за 150 мс сливаются в один запрос, одинаковые значения не
шлются, в полёте не больше одного запроса.

**Кэш.** `agent.cache_until` = время отправки запроса, который читал или писал кэш,
плюс время жизни: 1 час, если запрос записал часовые записи
(`ephemeral_1h_input_tokens` > 0 — так Claude Code делает на подписке Max), 5 минут для
пятиминутных; запрос, который только читал, продлевает с прошлым временем жизни. Пока
запрос идёт, кэш уже считается продлённым с момента отправки (как в pi-statusline).

**Лимиты.** На подписке claude.ai `session.measure` и `$.session.usage()` дают окна
`five_hour` и `seven_day` (`percentUsed`, `resetsAt`). Мод пишет их в `limits` (схема 1)
как окна `5h` и `7d` с правилами слияния pi-herdr (CAS: `doc.get` → свёртка → `doc.set` с
версией, повтор при конфликте; внутри одного окна `used` только растёт; чтения за 500 мс —
одной записью). Пишет на первом измерении, при сдвиге окна на целый процент и в конце
каждого хода (иначе `at` устаревал бы: Claude меряет только на целых процентах). Ключ
аккаунта — первые 8 hex sha256 от `oauthAccount.organizationUuid` из `~/.claude.json`
(`$CLAUDE_CONFIG_DIR/.claude.json`) — совпадает с тем, что pi-herdr берёт из заголовка
`anthropic-organization-id` (проверено: оба пишут `claude.849d2d8c`), поэтому чтения Claude
Code и pi складываются в один аккаунт. `plan` — `organizationType` без `claude_` с уровнем
Max из `organizationRateLimitTier` (`max_5x`, `max_20x` → Max / Ultra в
`Limits.planName`). `host` — вывод `hostname`, как `os.hostname()` у pi. `claude -p` тоже
пишет лимиты, но не метки. Настроек у мода нет: лимиты пишутся всегда (опции в `userConfig`
Claude Code спрашивал бы при включении плагина).

## Установка

```
/plugin marketplace add wierdbytes/wierdr
/plugin install cc@wierdr
```

Маркетплейс — [`.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json) в
корне репозитория (`wierdr`, плагин `cc` из `./Integrations/claude-code`). Имя `cc`:
`claude`, `claude-*` и `claude-code` зарезервированы (`claude plugin validate` их не
пропускает). Для разработки — без установки: `claude --plugin-dir
Integrations/claude-code` или `CLAUDE_CODE_PLUGIN_DIRS`.

## Проверенные ловушки

- **`hc send <t> "/clear"` не выполняет команду.** hc оборачивает вставленный текст в
  `<hc from=…>…</hc>`, и Claude получает это сообщением (тратит ход). Команды набирать
  клавишами: `hc keys <t> / c l e a r`, затем `hc keys <t> enter`.
- **Foreground pid во время Bash остаётся Claude.** Проверено на 2.1.327: пока шла
  `sleep 6` из Bash‑инструмента, `foreground.pid` терминала каждую секунду был pid Claude
  (команды идут вне группы процессов терминала), так что Wierdr метки не отбрасывает.
  Запуск через `env VAR=… claude` тоже не мешает: `env` делает exec, pid тот же.
- **`session.start` не приходит после `/clear`, `/resume`, `/branch`**: приходит
  `session.end` с `reason` `clear` / `resume`, а id сессии меняется. Мод перечитывает
  `$.session.id()` позже (через 0,5 с и на следующих событиях). Проверено: после `/clear`
  `agent.session` сменился за секунду, `agent.ctx` и кэш пропали.
- **Effort до первого запроса — из настроек**, а модель может работать на другом: с
  `effortLevel: high` в настройках Haiku 5.5 показывал `high`, пока первый запрос не
  сообщил `medium`. Прочитать действующий уровень вне запроса mods API не даёт
  (`$.config.list()` его не содержит).
- **Правила mods API**, о которые спотыкаешься: нет Node API, npm, `setTimeout` (таймеры
  — `$.clock.after` / `every`); импорты только относительные и `claude-code`; каждый вызов
  пишется полностью `$.ns.method(...)` (валидатор не пропускает `$.agent.limits?.()` и
  передачу `$` в функцию, объявленную внутри `register`: такие помощники — на верхнем
  уровне файла); имя переменной окружения в `$.env.get` — строковым литералом. Свой
  отрезок времени хука — 10 с, все хуки `session.end` вместе — 1,5 с.
- **Pid Claude — через `$PPID`, не `$.process.hookEnv()`.** В 2.1.327 `hookEnv().CLAUDE_PID`
  есть, но в 2.1.319 метода `process.hookEnv` нет, и модуль, который его называет, не
  загружается целиком (`"process.hookEnv" is not an event`), хотя `claude plugin validate`
  той же версии его пропускает. Родитель процесса из `$.process.run` — сам Claude:
  проверено на обеих версиях, `agent.pid` = `foreground.pid`.
- **`settings.read` в тестах**: заглушка отвечает объектом настроек целиком
  (`{ value: { effortLevel: 'high' } }`), ключ из него достаёт сам тест‑кит.
- Запуск `claude` может сам обновить нативную установку — это нормально.

## Как проверить вживую

Настоящие агенты работают в том же herdr-core, поэтому — отдельные терминалы
`wierdrtest-cc-*`, отдельный документ лимитов и `--model haiku`:

```sh
mkdir -p /tmp/wierdrtest-cc
hc run --bg --no-parent --name wierdrtest-cc-1 --cwd /tmp/wierdrtest-cc -- \
  env WIERDR_CC_LIMITS_DOC=wierdrtest-limits ~/.local/bin/claude \
  --plugin-dir ~/me/dev/wierdr/Integrations/claude-code --model haiku
hc get wierdrtest-cc-1 --json            # labels, foreground.pid, status, records
hc send wierdrtest-cc-1 "Reply with exactly one word: ok"; hc wait wierdrtest-cc-1
printf '{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"wierdrtest-limits"}}\n' | hc connect
hc keys wierdrtest-cc-1 / e x i t; hc keys wierdrtest-cc-1 enter   # метки должны исчезнуть
```

Уборка: `hc rm` каждого `wierdrtest-cc-*` (`hc ls --all --json | grep -c wierdrtest` → 0),
документ обнулить `doc.set` с `value: null` и текущей версией (значение удаляется, версия
остаётся).

Что видно на 2.1.327 (2026‑11‑18, Haiku 5.5, подписка Max): при старте — `agent.app`,
`agent.pid` (= `foreground.pid`), `agent.model` `Claude Haiku 5.5`, `agent.model_id`
`claude-haiku-5-5`, `agent.provider` `anthropic`, `agent.effort` `high` (из настроек),
`agent.ctx_max` `1000000`, `agent.session`; после ответа — `agent.effort` `medium`,
`agent.ctx` `45115`, `agent.cache_ttl` `3600000`, `agent.cache_until` = отправка + 1 ч; с
фоновым саб‑агентом — `agent.subagents` `1` (и запись в `records`), после его конца метка
пропадает; `/model sonnet` без промпта сразу дал `Claude Sonnet 5.5`; после `/exit` меток нет.
В `wierdrtest-limits` — аккаунт `claude.849d2d8c` с теми же `used` и `resets_at`, что
pi-herdr записал в настоящий `limits`; `claude -p` в том же терминале меток не писал, а
лимиты обновил.

Тесты без сессии: `claude plugin test Integrations/claude-code` (чистая логика и хуки через
`claude-code/testing` с заглушками `hc connect`), `claude plugin validate
Integrations/claude-code` и `claude plugin validate .` (маркетплейс).
