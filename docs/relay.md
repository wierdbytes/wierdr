# Релей пушей

Пуш в копию Wierdr из App Store подписывается только ключом APNs нашей команды
([research/push-relay.md](research/push-relay.md)). Поэтому `wierdr-push` на Mac
пользователя решает, что и когда показать в Live Activity, а отправляет пуш релей: он
подписывает его нашим ключом. Релей — Cloudflare Worker в `Relay/` на
`https://relay.wierdr.workat.dev` (`workers.dev` выключен: один адрес, под правилами зоны).

```
iPhone (Wierdr)                     Mac (wierdr-push)                   релей (Worker)              APNs
 App Attest: ключ, аттестация ──────────────────────────────────────▶ /v1/attest, /v1/devices
 право на токен ──SSH──▶ запись в `wierdr-push` (relay_grant)
                                     start / channels / broadcast ───▶ права, пуш, учёт ────────▶ HTTP/2
```

Релей ничего не знает про агентов: пуши запечатаны ([live-activity.md](live-activity.md#запечатано)).
Он пропускает только пуши Wierdr нужного вида: проверяет поля и их формат, но не
криптографию печати. Наружу уходит JSON в том виде, как релей его разобрал и записал
заново, а не исходный текст (см. «Что пропускает»).

## Права

Релей не хранит, кому что можно: права — строки
`g2.<до когда, unix>.<владелец>.<mac>`. Владелец — 96 бит SHA‑256 идентификатора ключа
App Attest, которому право выдано. MAC — HMAC‑SHA256 секретом релея (`RELAY_SECRET`) над
версией, App ID (`AUL4CCB2XY.pw.xff.wierdr`), видом права, окружением APNs, токеном или
каналом, владельцем и сроком (`Relay/src/grants.ts`).

- **Право устройства** — на push‑to‑start токен на 30 дней. Его получает приложение,
  доказав через App Attest, что оно настоящий Wierdr, и кладёт в свою запись документа
  `wierdr-push` (`relay_grant`). С ним демон стартует там активность и заводит каналы.
- **Право канала** — на канал, на 30 дней; релей выдаёт его вместе с каналом, владелец тот
  же. С ним демон шлёт update и end и удаляет канал. Демон хранит их в `push-state.json`
  (`channelGrants`). Старт тоже требует право канала, и `input-push-channel` в пуше должен
  быть этим каналом: чужое право устройства не подпишет телефон на чужой канал.
- **Отзыв.** Любое право проверяется вместе с ключом владельца в D1. Если ключ отозван
  (`POST /v1/admin/keys/revoke`) или его нет, ответ `403 key_revoked`. Удалить канал можно
  и с истёкшим правом, и с отозванным ключом: уборке это не мешает.
- **Приложение** при каждом подключении к Mac спрашивает `POST /v1/grants/check`, держится
  ли право. Право просится заново, если релей его не принял, если оно подписано прошлым
  секретом (`renew`), если до конца меньше 10 дней или если сменился токен
  (`WierdrRelay/RelayRegistration.swift`).
- **Смена секрета** мягкая. Новый ставится в `RELAY_SECRET`, старый на время — в
  `RELAY_SECRET_PREVIOUS`. Права по старому держатся до своего срока, но помечены к замене,
  и приложения берут новые при подключении. Без `RELAY_SECRET_PREVIOUS` все старые права
  сразу недействительны, и до подключения Wierdr активности на этом устройстве нет.
- **Демон** не шлёт на устройство, чьё право релей отверг (`badGrants`, пока приложение не
  принесёт новое). Истёкшее право релей отвергает сам, поэтому срок демон не проверяет.
  Канал он заводит по праву с самым поздним сроком.

## App Attest

Ключ в Secure Enclave, который Apple заверяет как ключ настоящего Wierdr на настоящем
устройстве. Логика — в `Packages/WierdrKit/Sources/WierdrRelay/RelayRegistration.swift`
(с тестами), DeviceCheck и UserDefaults — в `App/Sources/Activity/RelayRegistration.swift`.

1. **Один раз после установки:** `generateKey()`, вызов `POST /v1/challenge`,
   `attestKey(key, SHA256(вызов))`, `POST /v1/attest {key_id, attestation, challenge}`.
   Релей проверяет аттестацию по шагам Apple (`Relay/src/appattest.ts`):
   - в `x5c` ровно два сертификата; цепочка до корня App Attest (вшит в `src/roots.ts`,
     действует до 2045); промежуточный — CA, лист — нет (`basicConstraints`);
   - nonce в сертификате, что `key_id` — хеш ключа, хеш App ID, счётчик 0, `aaguid`
     (development/production), `credentialId`;
   - категория сборки из `extensions` (iOS 27): только 2–5, то есть TestFlight,
     development, App Store, ad‑hoc.

   Любая ошибка разбора — `403 bad_attestation`, а не 500. Открытый ключ, окружение,
   категория, версия бандла и квитанция Apple (для будущей оценки риска) ложатся в D1
   (`attest_keys`).
2. **Каждая регистрация:** новый вызов, тело `{challenge, key_id, token, env}`, утверждение
   `generateAssertion(key, SHA256(тело))` в заголовке `X-Wierdr-Assertion`,
   `POST /v1/devices`. Релей проверяет подпись над `SHA256(authenticatorData ‖ SHA256(байты
   тела))`, хеш App ID и что счётчик вырос (одна условная запись в D1: повтор получит 409),
   и отвечает правом устройства.
3. **Ключ не получает права на любые токены:** не больше 5 разных за 30 дней
   (`device_tokens`), иначе `429 too_many_tokens`.

Вызовы без состояния: `c1.<время>.<случайное>.<mac>`, живут 5 мин. Повтор аттестации
безвреден: ключ уже записан и сверяется. Утверждения защищены счётчиком.

**Окружения.** Ключ из development‑окружения App Attest не получает право на
production‑токен. Копия из TestFlight или App Store (категории 2 и 4) получает права
только на production. Остальные production‑ключи годятся для обоих окружений: `make ipa`
(экспорт Xcode) ставит сборке для разработки `appattest-environment = production`, хотя в
архиве `development` (проверено 2026‑11‑19). Окружение APNs приложение берёт из
`embedded.mobileprovision`. В TestFlight и App Store этого файла нет, а пуши там идут через
production, поэтому без файла окружение — `production`.

**Что идёт не так, и что делает приложение** (не больше двух кругов за вызов):

| Случай | Что делает приложение |
|---|---|
| Ключ, который Secure Enclave потерял (`DCError.invalidKey`, восстановление из копии на другом устройстве: id ключа в UserDefaults переносится, сам ключ нет) | Делает новый ключ |
| Релей не знает ключ (`401 unknown_key`, база сброшена) | Тоже делает новый ключ и заверяет его |
| Сервис Apple недоступен (`serverUnavailable`) | Ключ сохраняет, пробует позже |
| Другая ошибка `attestKey` | Ключ выбрасывает, как велит Apple |
| Релей отверг аттестацию (403/409) или ключ отозван | Не заверяет заново сутки: Apple ограничивает аттестации, а частые выглядят как мошенничество |

В симуляторе App Attest нет, права там не будет, и через релей пуши туда не пойдут.

## Каналы

APNs держит не больше 10 000 каналов на приложение в каждом окружении, и канал живёт,
пока его не удалят (документация Apple, «Sending channel management requests»). Поэтому
релей ведёт им учёт (`channels` в D1).

- **Ключу** можно не больше 30 новых каналов в сутки и не больше 20 живых одновременно
  (`429 channel_quota`, `429 channel_limit`). Приложению в окружении — не больше 8 000
  живых (`503 channels_full`, в журнал ошибкой). Неудачное создание в APNs квоту не тратит.
- **Каждый час** (cron) релей удаляет в APNs каналы старше их права (30 дней и сутки
  запаса) и чистит старые строки.
- **Демон** удаляет каналы через очередь с повторами (`pendingDeletes` в `push-state.json`),
  а не одной попыткой. Новый запасной канал он заводит до удаления старого.
- **Сверка.** `POST /v1/admin/channels {env, purge}` (с `Authorization: Bearer
  <ADMIN_TOKEN>`; на mentoair токен в `~/.config/wierdr/relay-admin-token`) сверяет список
  APNs (`all-channels`) с учётом. Каналы, которых в учёте
  нет, при `purge: true` удаляются, по 40 за вызов. Осторожно: каналы, созданные напрямую
  (демон с ключом на Mac, тот же bundle и окружение), для релея тоже неизвестны.

## Что пропускает

`Relay/src/payload.ts`: только Live Activity Wierdr, запечатанная, ничего лишнего.

- Не больше 4 КБ уже в том виде, какой уйдёт в APNs. Ровно `{"aps": …}`.
- У start: `timestamp`, `event`, `content-state`, `input-push-channel` (канал старта),
  `attributes-type` (`AgentsActivityAttributes`), `attributes` (`{sealed, kid}`), `alert`,
  `stale-date`.
- У update: `timestamp`, `event`, `content-state`, `alert`, `stale-date`; у end:
  `timestamp`, `event`, `content-state`, `dismissal-date`.
- `content-state` — ровно `blocked, done, working, idle` (целые ≥ 0), `at`, `sealed`, `kid`
  (8 строчных hex).
- `alert` — только слова Wierdr: заголовок `Wierdr`, `Needs you` или `Done`, текст — строка
  счётчиков (`1 needs you · 2 working`, `4 idle`, `No agents`), `sound` только `default`.
  Чужой текст на экран блокировки с утёкшим правом не попадёт.
- Пуш разбирается и записывается заново (`JSON.stringify`): ключ, повторённый в JSON, не
  покажет APNs и iOS не то, что проверено. `JSON.parse` берёт последний дубль, а
  Foundation — первый.
- Тему (`pw.xff.wierdr.push-type.liveactivity`) и тип пуша ставит релей. Каждый вызов демона
  называет bundle (`bad_bundle`, если он не релея). У старта `apns-expiration` — 10 мин:
  телефон, бывший вне сети, не получит через час старт на давно удалённом канале.

Контракт проверяется тестами с обеих сторон. `WIERDR_WRITE_FIXTURES=1 swift test` пишет
`Relay/test/fixtures/swift-payloads.json` из `ActivityPayload` и `Planner`. Обычный
`swift test` проверяет, что поля не изменились, а `bun test` — что релей всё это
принимает и что ничего агентского там нет в открытом виде.

## Лимиты

- Привязки Rate Limiting (считает каждая точка Cloudflare отдельно и примерно):
  - `LIMIT_APP` — 20 в минуту на адрес клиента (IPv6 — по /64) и на ключ App Attest
    (по нормализованному base64: разное написание одного ключа считается вместе);
  - `LIMIT_ATTEST` — 5 аттестаций в минуту на адрес;
  - `LIMIT_PUSH` — 60 в минуту на токен или канал, после проверки права.
- Тело не больше 20 КБ, по `content-length` ещё до чтения.
- JWT для APNs один на 30‑минутное окно и ключ. Он общий для всех изолятов через D1
  (`apns_jwt`): из двух, подписанных одновременно, остаётся первый записанный, и им
  пользуются оба. После `InvalidProviderToken` или `ExpiredProviderToken` он сбрасывается.
  APNs не любит провайдер‑токены, обновлённые чаще раза в 20 мин.

## Демон через релей

В `~/.config/wierdr/push.json` добавить `"relay": "https://relay.wierdr.workat.dev"`. С ним
`PushConfig.transport()` даёт `RelayClient`, без него — `APNsClient` с ключом (поля ключа
тогда можно не указывать). Отказы APNs релей возвращает как есть
(`502 {"error": "apns", "status", "reason"}`), и демон читает их как напрямую (плохой
токен, плохой канал). Отвергнутое право канала читается как плохой канал: следующая
активность будет на новом. Отказ при создании канала откладывает только эту полосу, а не
все пуши. `wierdr-push status` показывает транспорт, право каждого устройства (и
отвергнуто ли оно) и очередь удаления. На mentoair демон ходит через релей
(`push.json.direct` — прежний конфиг). Переходя с прямого режима на релей, сначала
`wierdr-push reset`: каналы, созданные напрямую, через релей не удалить.

## Развёртывание

```sh
cd Relay
bun install
bun test                       # App Attest на настоящих объектах (iOS 27, procivis/one-core), права, пуши через роутер, контракт со Swift
bun run check                  # tsc
bunx wrangler d1 create wierdr-relay           # один раз; id — в wrangler.jsonc
bun run schema                                 # схема D1 (можно повторять)
bunx wrangler secret put APNS_KEY < ~/.config/wierdr/AuthKey_N3XU3N4B8V.p8
openssl rand -base64 32 | tr -d '\n' | bunx wrangler secret put RELAY_SECRET
openssl rand -base64 32 | tr -d '\n' | tee ~/.config/wierdr/relay-admin-token | bunx wrangler secret put ADMIN_TOKEN
bun run deploy                 # воркер, cron и Custom Domain relay.wierdr.workat.dev
bunx wrangler tail             # журнал (только наши строки: журналы вызовов с адресами выключены)
```

## Проверенные ловушки

- Исходящий `fetch` воркера к APNs идёт по HTTP/2, но только на edge Cloudflare. Локальный
  `wrangler dev` (workerd) до APNs не достаёт (cloudflare/workerd#4841). Тесты подменяют
  `fetch`. С edge (2026‑11‑19, sandbox): start на выдуманный токен — `400 BadDeviceToken`,
  канал на порту 2195 создан, broadcast принят, канал удалён. Production (порт 2196) через
  релей ещё не проверялся.
- `fetch`, вызванный как метод чужого объекта (`this.fetcher(...)`), в Workers падает с
  «Illegal invocation». Его надо оборачивать в стрелку или вызывать отдельной переменной.
- Сертификат Custom Domain для `relay.wierdr.workat.dev` (второй уровень, его выпускает
  Advanced Certificate, бесплатно) появился через несколько минут после деплоя. До того
  TLS‑рукопожатие падало.
- `xcodebuild -allowProvisioningUpdates` иногда пишет «No Accounts», когда аккаунт в Xcode
  есть. Повтор помог.

## Что осталось до App Store

- **Ключ APNs.** Отдельный ключ только для `pw.xff.wierdr` вместо командного N3XU3N4B8V.
  Релей обслуживает и sandbox, и production, поэтому ключ нужен без ограничения окружения
  или два ключа (`wrangler secret put APNS_KEY`, `APNS_KEY_ID` в `wrangler.jsonc`).
- **Оценка риска App Attest.** Квитанции сохраняются, но оценку риска Apple (fraud metric)
  релей пока не запрашивает. Версия бандла (`apple_bundle_version_01`) хранится, но не
  сверяется.
- **Privacy policy и App Privacy:** токены устройств (хешами в D1), ключи App Attest и
  квитанции уходят на наш сервер.
