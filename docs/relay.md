# Релей пушей

Пуш в копию Wierdr из App Store подписывается только ключом APNs нашей команды
([research/push-relay.md](research/push-relay.md)). Поэтому `wierdr-push` на Mac
пользователя решает, что и когда показать в Live Activity, а отправляет пуш релей: он
подписывает его нашим ключом. Релей — Cloudflare Worker в `Relay/`, живёт на
`https://relay.wierdr.workat.dev` (и `wierdr-relay.a-08f.workers.dev`).

```
iPhone (Wierdr)                     Mac (wierdr-push)                   релей (Worker)              APNs
 App Attest: ключ, аттестация ──────────────────────────────────────▶ /v1/attest, /v1/devices
 право на токен ──SSH──▶ запись в `wierdr-push` (relay_grant)
                                     start / channels / broadcast ───▶ проверка права и пуша ───▶ HTTP/2
```

Релей ничего не знает про агентов: пуши запечатаны ([live-activity.md](live-activity.md#запечатано)),
и он пропускает только такие.

## Права

Релей не хранит, кому что можно: права — строки, подписанные HMAC его секретом
(`RELAY_SECRET`), `g1.<до когда, unix>.<mac>`.

- **Право устройства** — на push‑to‑start токен (в окружении APNs) на 30 дней. Его получает
  приложение, доказав App Attest, что оно настоящий Wierdr, и кладёт в свою запись в
  документе `wierdr-push` (`relay_grant`). С ним демон стартует там активность и заводит
  каналы.
- **Право канала** — на канал, на 30 дней; релей выдаёт его вместе с каналом. С ним демон
  шлёт update и end и удаляет канал. Демон хранит их в `push-state.json`
  (`channelGrants`).
- Приложение просит право заново за 10 дней до конца и при новом токене. Демон не шлёт на
  устройство, чьё право кончается в ближайшие сутки или было отвергнуто (`badGrants`, пока
  приложение не принесёт новое), и меняет запасной канал, если его праву осталось меньше
  двух дней.
- Смена `RELAY_SECRET` отменяет все права: приложения возьмут новые при следующем
  подключении, демон заведёт новые каналы.

## App Attest

Ключ в Secure Enclave, который Apple заверяет как ключ настоящего Wierdr
(`AUL4CCB2XY.pw.xff.wierdr`) на настоящем устройстве (`App/Sources/Activity/RelayRegistration.swift`):

1. Один раз после установки: `DCAppAttestService.generateKey()`, вызов `POST /v1/challenge`,
   `attestKey(key, SHA256(вызов))`, `POST /v1/attest {key_id, attestation, challenge}`.
   Релей проверяет аттестацию по шагам Apple (`Relay/src/appattest.ts`):
   - цепочку до корня App Attest (вшит в `src/roots.ts`, действует до 2045);
   - nonce в сертификате;
   - что `key_id` — хеш ключа;
   - хеш App ID, счётчик 0, `aaguid` (development/production), `credentialId`;
   - категорию сборки из `extensions` (iOS 27): 2–5, то есть TestFlight, development,
     App Store, ad‑hoc.

   Открытый ключ ложится в D1 (`attest_keys`).
2. Каждая регистрация: новый вызов, тело `{challenge, key_id, token, env}`, утверждение
   `generateAssertion(key, SHA256(тело))` в заголовке `X-Wierdr-Assertion`,
   `POST /v1/devices`. Релей проверяет подпись над `SHA256(authenticatorData ‖ SHA256(тело))`,
   хеш App ID и что счётчик вырос, и отвечает правом устройства.

Вызовы без состояния: `c1.<время>.<случайное>.<mac>`, живут 5 мин. От повтора защищает
счётчик утверждений, обновляемый в D1 одной условной записью. Если релей не знает ключ
(`401 unknown_key`, база сброшена), приложение заверяет его заново. Если Secure Enclave
ключ потерял (`DCError.invalidKey`, восстановление из копии), приложение делает новый.

Ключ из development‑окружения App Attest не получает право на production‑токен. Ключ из
production годится для обоих: `make ipa` (экспорт Xcode) ставит сборке для разработки
`appattest-environment = production`, хотя в архиве `development` (проверено 2026‑11‑19).
В симуляторе App Attest нет, права там не будет, и через релей пуши туда не пойдут.

## Что пропускает

`Relay/src/payload.ts`: только Live Activity Wierdr и только запечатанная, ничего лишнего.

- Не больше 4 КБ, ровно `{"aps": …}`.
- У start: `timestamp`, `event`, `content-state`, `input-push-channel`, `attributes-type`
  (`AgentsActivityAttributes`), `attributes` (`{sealed, kid}`), `alert`, `stale-date`.
- У update: `timestamp`, `event`, `content-state`, `alert`, `stale-date`; у end: `timestamp`,
  `event`, `content-state`, `dismissal-date`.
- `content-state` — ровно `blocked, done, working, idle, at, sealed, kid`.
- `alert` — `title` ≤ 64, `body` ≤ 160, `sound` только `default`.

Тема (`pw.xff.wierdr.push-type.liveactivity`) и тип пуша (`liveactivity`) — релея, не
демона.

## Лимиты

- Привязки Rate Limiting: `LIMIT_APP` — 20 в минуту на адрес (challenge, attest) и на ключ
  App Attest (devices); `LIMIT_PUSH` — 60 в минуту на токен или канал. Считает каждая точка
  Cloudflare отдельно и примерно.
- Не больше 100 каналов в сутки на устройство (D1 `channel_quota`).
- JWT для APNs один на 30‑минутное окно и общий для всех изолятов через D1 (`apns_jwt`):
  APNs не любит провайдер‑токены, обновлённые чаще раза в 20 мин.

## Демон через релей

В `~/.config/wierdr/push.json` добавить `"relay": "https://relay.wierdr.workat.dev"`. С ним
`PushConfig.transport()` даёт `RelayClient`, без него — `APNsClient` с ключом (поля ключа
тогда можно не указывать). Отказы APNs релей возвращает как есть
(`502 {"error": "apns", "status", "reason"}`), и демон читает их как напрямую (плохой
токен, плохой канал). Отвергнутое право канала читается как плохой канал: следующая
активность — на новом. `wierdr-push status` показывает транспорт и право каждого
устройства. Сейчас на mentoair демон ходит через релей (`push.json.direct` — прежний
конфиг).

## Развёртывание

```sh
cd Relay
bun install
bun test                       # App Attest на настоящих объектах (iOS 27, procivis/one-core), права, пуши через роутер
bun run check                  # tsc
bunx wrangler d1 create wierdr-relay           # один раз; id — в wrangler.jsonc
bun run schema                                 # схема D1 (можно повторять)
bunx wrangler secret put APNS_KEY < ~/.config/wierdr/AuthKey_N3XU3N4B8V.p8
openssl rand -base64 32 | tr -d '\n' | bunx wrangler secret put RELAY_SECRET
bun run deploy                 # воркер и Custom Domain relay.wierdr.workat.dev
bunx wrangler tail             # журнал
```

## Проверенные ловушки

- Исходящий `fetch` воркера к APNs идёт по HTTP/2, но только на edge Cloudflare. Локальный
  `wrangler dev` (workerd) до APNs не достаёт (cloudflare/workerd#4841). Тесты подменяют
  `fetch`. С edge (2026‑11‑19): start на выдуманный токен — `400 BadDeviceToken`, канал на
  порту 2195 создан, broadcast принят, канал удалён.
- `fetch`, вызванный как метод чужого объекта (`this.fetcher(...)`), в Workers падает с
  «Illegal invocation». Его надо оборачивать в стрелку или вызывать отдельной переменной.
- Сертификат Custom Domain для `relay.wierdr.workat.dev` (второй уровень, его выпускает
  Advanced Certificate, бесплатно) появился через несколько минут после деплоя. До того
  TLS‑рукопожатие падало, а `workers.dev` уже работал.
- `xcodebuild -allowProvisioningUpdates` иногда пишет «No Accounts», когда аккаунт в Xcode
  есть. Повтор помог.

## Что осталось до App Store

- Отдельный ключ APNs только для `pw.xff.wierdr` вместо командного N3XU3N4B8V
  (`wrangler secret put APNS_KEY`, `APNS_KEY_ID` в `wrangler.jsonc`).
- Квитанция App Attest и оценка риска (fraud metric) Apple: сейчас не проверяются.
- Privacy policy и App Privacy: токены устройств и ключи App Attest уходят на наш сервер.
- Есть ли у Apple предел каналов на приложение, по‑прежнему неизвестно.
