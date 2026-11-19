# pi в Wierdr и herdr

pi в терминале herdr-core показывается в Wierdr со всеми данными благодаря расширению
`@wierdbytes/pi-wierdr` из этого репозитория ([`Integrations/pi`](../Integrations/pi/README.md)).
Статус (`idle` / `working` / `blocked` / `done`, `msg`) pi шлёт сам по OSC 7501; всё
остальное — расширение. В нём две половины:

- **`herdr/`** — метки `agent.*` на терминале pi, лимиты подписок Claude и Codex в документ
  `limits`, команды bash в своих терминалах herdr-core под терминалом pi. До 0.1.0 —
  `@wierdbytes/pi-herdr` (последняя 0.6.1) в репозитории `pi-wierd-stuff`.
- **`agents/`** — сабагенты: каждый — свой интерактивный pi в дочернем терминале herdr-core
  (инструменты `Agent`, `get_subagent_result`, `steer_subagent`, `stop_subagent`, RPC по
  `pi.events`). До 0.1.0 — `@wierdbytes/pi-agents` (последняя 0.1.3) там же.

Wierdr читает метки и документ тем же кодом, что у Claude Code ([claude-code.md](claude-code.md))
и Codex ([codex.md](codex.md)): `AgentLabels.meta` в `TerminalFacts.swift`, `Limits.swift`.

Ставится `pi install npm:@wierdbytes/pi-wierdr`; Wierdr предлагает это сам, когда находит pi
≥ 1.5.0 на компьютере, и заодно убирает `pi-herdr` и `pi-agents` ([host-setup.md](host-setup.md)).

## Что откуда

| Что | Откуда | Где в herdr-core |
|---|---|---|
| Статус, `msg` | pi сам, OSC 7501 (`app: "pi"`) | `status` терминала |
| Модель, провайдер, effort, контекст, окно, сессия, кэш, pid | `herdr/` (`meta.ts`, `publisher.ts`) | метки `agent.*` |
| Лимиты подписки (Claude, Codex) | `herdr/` (`limits.ts`, `limits-publisher.ts`) | документ `limits` |
| Команды bash (модели и `!`) | `herdr/` (`bash.ts`, `bash-tool.ts`) | дочерние терминалы с меткой `pi-herdr.bash` |
| Сабагенты | `agents/` (`manager.ts`) | дочерние терминалы с метками `pi-agents.*`, у каждого свои `agent.*` и 7501 |
| Число сабагентов `@tintinweb/pi-subagents` (в процессе pi) | `herdr/` (`subagents.ts`) | метка `agent.subagents` |

Таблица меток с примерами, формат `limits`, поведение bash и сабагентов — в
[README пакета](../Integrations/pi/README.md); устройство сабагентов (протокол
родитель ↔ ребёнок, подхват после `/reload`) — в [research/pi-agents.md](research/pi-agents.md).

## Почему здесь и одним пакетом

- Главный читатель меток и документа — Wierdr; их формат меняется вместе с приложением и
  плагинами `cc` и `codex`, которые пишут то же самое. Теперь это один коммит, а не два
  репозитория.
- Обе половины ставились всегда вместе и обе работают только в терминале herdr-core.
  Одна точка входа (`index.ts`) вызывает обе; кода у них общего нет (у каждой свой
  `hc.ts`), объединять его не стали, чтобы перенос ничего не менял в поведении.

## Что не переименовано

Имена, которые видят другие программы или сохранённые сессии, остались прежними:

- метки `pi-agents.run` / `pi-agents.pid` / `pi-agents.type` — по ним pi после `/reload`
  находит свои сабагенты, в том числе запущенные до обновления;
- метка `pi-herdr.bash` (`tool` / `user`) — для модов, которые отличают терминалы команд;
- переменные `PI_AGENTS_*` — их убирают pi-web и pi-voice из `pi -p`, который запускают,
  чтобы тот не принял себя за сабагента;
- тип сообщения `pi-agents:notification` — в старых сессиях;
- RPC `agents:rpc:<метод>` и события `agents:*`.

Переименовано: настройки — один файл `~/.pi/agent/@wierdbytes/pi-wierdr/settings.json`
(`bash` и ключи сабагентов под `agents`; пока его нет, читаются старые
`@wierdbytes/pi-herdr/settings.json` и `@wierdbytes/pi-agents/settings.json`), файлы
сабагентов — `~/.pi/agent/@wierdbytes/pi-wierdr/runs`, клиент RPC —
`@wierdbytes/pi-wierdr/client`, сообщения pi — `pi-wierdr: …`.

## Разработка

```sh
cd Integrations/pi
bun install          # bun.lock — канонический
bun run test         # vitest
pi -ne -e ./index.ts # проверить без установленной копии (-ne: без остальных расширений)
```

С установленным `npm:@wierdbytes/pi-wierdr` второй экземпляр через `-e` не загрузить:
инструменты `Agent` и др. регистрируются дважды. Поэтому `-ne`.

## Публикация в npm (OIDC)

- [`.github/workflows/publish-pi.yml`](../.github/workflows/publish-pi.yml) запускается на
  push в `master`, если изменилось что-то в `Integrations/pi/**` (или вручную,
  `workflow_dispatch`). Если версии из `package.json` ещё нет в npm — `bun install
  --frozen-lockfile`, тесты, `npm publish`. Аутентификация — Trusted Publishing (OIDC),
  без токенов и секретов.
- Trusted Publisher пакета: GitHub, `wierdbytes/wierdr`, файл `publish-pi.yml`, право
  publish (`npm trust list @wierdbytes/pi-wierdr`). Переименовал файл — регистрируй заново
  (`npm trust github @wierdbytes/pi-wierdr --file <файл> --repo wierdbytes/wierdr
  --allow-publish --yes`, нужен `npm login`).
- **Выпуск:** поднять `version` в `Integrations/pi/package.json`, добавить сверху
  `CHANGELOG.md` запись `## <version>` (строки `**New:**` / `**Fix:**` / `**Change:**` /
  `**Removed:**` / `**Breaking:**`, одна строка — что изменилось для пользователя;
  pi показывает её после обновления), коммит, push. **Push в `master` с поднятой версией
  публикует пакет — только с разрешения.** Коммит сам ничего не публикует.
- После выпуска: `pi update npm:@wierdbytes/pi-wierdr` (npm может несколько минут отдавать
  прежнюю версию), затем `/reload` в запущенных pi.

Проверенные ловушки:

- Репозиторий приватный: OIDC работает, а provenance npm не делает. `repository.url` в
  `package.json` обязан совпадать с репозиторием (`git+https://github.com/wierdbytes/wierdr.git`),
  иначе OIDC не проходит.
- Trusted Publisher настраивается только у пакета, который уже есть в npm, а новая связь
  должна пройти первую публикацию из CI за 2 дня, иначе истекает. Поэтому `0.0.0` (тот же
  код) опубликована вручную и помечена deprecated, а `0.1.0` — первая из CI.
- OIDC нужен npm ≥ 11.5.1 и Node ≥ 22.14: в CI — Node 24 и `npm install -g npm@latest`.
