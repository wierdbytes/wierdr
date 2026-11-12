# Live Activity агентов

Пока хоть один агент работает, закончил (и ты ещё не смотрел) или ждёт тебя, на экране
блокировки iPhone, в Dynamic Island и в Smart Stack часов висит Live Activity Wierdr.
В ней:

- счётчики по статусам: `! 1 · ● 2 · ◔ 3` (нужен ты, закончил, работает), как группы
  списка агентов на iPhone (агент считается там же, куда его поставил бы самый срочный
  его саб‑агент);
- до 4 агентов (в Dynamic Island до 3) в порядке списка: статус, иконка программы,
  заголовок строки, спейс (и машина, если агент не на этом компьютере), сколько агент в
  этом статусе, как в сайдбаре (`28m`, `3h`, `2d`; первую минуту `<1m`);
- тап по агенту открывает Wierdr сразу на его панели (`wierdr://agent?t=<адрес>`).

Когда агент начинает ждать тебя, экран загорается, Dynamic Island раскрывается и звучит
звук: «Needs you — <заголовок> — <спейс>». Когда агент закончил, экран тоже загорается и
остров раскрывается, но без звука. Если все агенты простаивают дольше 20 с, Live Activity
закрывается, а когда кто‑то снова начинает работать, открывается новая.

## Как это устроено

```
iPhone (Wierdr)                          Mac (herdr-core + wierdr-push)                 APNs
 ActivityKit: push-to-start token ──SSH──▶ документ `wierdr-push` в ядре
                                           wierdr-push: зеркало ядра (WorkspaceEngine,
                                           только чтение) → сводка → Planner
                                             start (на токен устройства) ─────────────▶ ─┐
                                             update / end (broadcast на канал) ───────▶ ─┤
 Lock Screen / Dynamic Island ◀────────────────────────────────────────────────────────── ┘
```

- **Регистрация.** Приложение получает от ActivityKit push‑to‑start токен и, когда сессия
  становится живой (а также при смене токена, настройки Live Activities или появлении и
  исчезновении активности), записывает свою запись в документ `wierdr-push` того
  компьютера, к которому подключено: имя, bundle id, окружение APNs (`aps-environment` из
  профиля), токен и есть ли сейчас на телефоне активность. Запись идёт через `doc.set` с CAS.
  Если Live Activities для Wierdr выключены, запись удаляется.
- **`wierdr-push`** на Mac (launchd, `scripts/push-agent.sh`). Это `WorkspaceEngine` в
  режиме только чтения над локальным `hc connect`, то есть тот же разбор, что в приложении.
  Раз в секунду он строит сводку (`ActivitySummary`: `Workspace.inbox`, общий со списком
  агентов на iPhone) и отдаёт её `Planner`. Тот решает, что слать:
  - есть активные агенты и нет активности → **push‑to‑start** на токен каждого устройства с
    `input-push-channel` (iOS 18), так что активность сразу подписана на канал;
  - сводка изменилась → **broadcast update** на канал. Если изменились статусы (счётчики
    или какой агент в каком статусе, в том числе «done снят в другом клиенте»), update
    уходит сразу с `apns-priority: 10`; если агент стал «нужен ты» или «закончил», ещё и
    с alert. Изменения без смены статусов (заголовок, модель) идут с priority 5 не чаще
    раза в 5 с;
  - **время** (`28m`) виджет считает сам в момент отрисовки, без тика, поэтому демон
    присылает обновление (priority 5), когда показанное значение сменилось бы: раз в
    минуту, пока какому‑то агенту меньше часа, потом раз в час. Первую минуту вместо
    секунд, которые до следующего обновления стояли бы на месте, показывается `<1m`.
    Сама Live Activity без пушей обновляет только `Text(date, style: .timer / .relative / .offset)` и
    `Text(timerInterval:)` (`21:13`, `21 min, 13 sec`, `+21 minutes`). Формат сайдбара
    даёт `Text(.durationOffset(to:), format: .units(width: .narrow, maximumUnitCount: 1))`
    (iOS 18), но в Live Activity такой текст (как и любой `Text(TimeDataSource, format:)`)
    не отрисовывается: карточка обрывается на нём и на iOS 18.4, и на iOS 27
    (проверено 2026‑11‑12);
  - раз в 10 мин heartbeat сдвигает `stale-date` (25 мин). Если Mac уснул, активность
    через 25 мин помечается «Not updated»;
  - если запускать нечего, кроме агентов «закончил», старт ждёт 5 с: если их тут же
    посмотрели в другом клиенте, Live Activity не появляется;
  - нет активных агентов → сразу update (так виджет перестаёт показывать снятый done),
    через 20 с **broadcast end** (priority 10), активность убирается сразу;
  - активность живёт 7 ч 45 мин → end и новый start (ActivityKit сам закрывает её через 8 ч);
  - новое устройство или новый токен → start только на нём, на тот же канал;
  - приложение записало, что активности на телефоне нет (позже чем через 15 с после её
    start: смахнули, переустановили) → start на этом устройстве ещё раз.
- **Канал у каждой активности свой.** Он создаётся заранее, как запасной для следующего
  старта, а после end удаляется: так end старой активности не может закрыть новую.
  Политика канала — «ничего не хранить» (`message-storage-policy: 0`,
  `apns-expiration: 0`): у канала, хранящего последнее сообщение, бюджет публикаций
  гораздо меньше, APNs отвечал `429 TooManyRequests` уже после ~20 обновлений за 13 мин.
  Цена: телефон, который был вне сети, увидит актуальное состояние со следующим
  обновлением (а оно приходит хотя бы раз в минуту, пока тикает время). Запасные каналы,
  идущие активности и отвергнутые токены лежат в `~/.config/wierdr/push-state.json`,
  поэтому перезапуск демона продолжает ту же активность.
- **Подпись запросов**: токен JWT (ES256) от `.p8` ключа APNs команды, переиспользуется
  50 мин; HTTP/2 через `URLSession`.
- Приложение, если на телефоне оказалось две активности Wierdr (start разминулся с end),
  оставляет последнюю.

Код: `Packages/WierdrKit/Sources/WierdrActivity` (атрибуты, состояние, документ, ссылка;
общий для приложения, виджета и Mac), `WierdrPush` (`ActivitySummary`, `Planner`,
`ActivityPayload`, `APNsClient`, `Pusher`), `wierdr-push` (CLI); в приложении
`App/Sources/Activity/LiveActivities.swift` и виджет `App/Widgets/`.

## Настройка (один раз)

1. **developer.apple.com → Certificates, IDs & Profiles**, команда `AUL4CCB2XY`:
   - **Keys → +**: включить *Apple Push Notifications service (APNs)* (окружение
     Sandbox & Production), скачать `AuthKey_XXXXXXXXXX.p8`. Ключ скачивается один раз.
   - **Identifiers → `pw.xff.wierdr`**: включить *Push Notifications* и в нём галку
     **Broadcast Capability**. Без Broadcast каналы не создаются.
   - Подписи нужен профиль с push для `pw.xff.wierdr`: прежний wildcard‑профиль
     (`iOS Team Provisioning Profile: *`) push не включает, а виджету `pw.xff.wierdr.widgets`
     хватает и его. Проще всего войти в Xcode (Settings → Accounts) этой командой:
     `make ipa` / `make device` с `-allowProvisioningUpdates` сами заведут App ID и профиль.
     Если ASC API пишет `REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`, сначала нужно принять
     соглашение в developer account.
2. На Mac:
   ```sh
   mkdir -p ~/.config/wierdr && mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.config/wierdr/
   cat > ~/.config/wierdr/push.json <<'EOF'
   {"key_file": "~/.config/wierdr/AuthKey_XXXXXXXXXX.p8", "key_id": "XXXXXXXXXX", "team_id": "AUL4CCB2XY"}
   EOF
   scripts/push-agent.sh install      # release-сборка → ~/.local/share/wierdr-push (+ ссылка в ~/.local/bin), LaunchAgent
   ```
3. Поставить на iPhone сборку с Live Activity (`make ipa && scripts/iphone.sh install`) и
   один раз открыть Wierdr, подключённый к этому Mac. В **Settings → Live Activity**
   должно стать «On mentoair».
4. Первая Live Activity придёт с вопросом iOS «Allow Live Activities from Wierdr?» → Allow.

Проверка и обслуживание:

```sh
scripts/push-agent.sh status   # launchd + конфиг, устройства, канал, идущая активность, сводка сейчас
scripts/push-agent.sh log      # что и когда отправлено (start/update/end, ошибки APNs)
wierdr-push reset              # закончить идущую активность, удалить каналы, забыть отвергнутые токены
```

Посмотреть активность без APNs в симуляторе (DEBUG):
`xcrun simctl launch <sim> pw.xff.wierdr -demo YES -live-activity-demo YES`, затем
заблокировать экран (`scripts/iphone-sim.sh` с WDA: `curl -X POST localhost:<port>/wda/lock`).

## Ограничения

- Только iPhone. На iPad iOS не показывает Live Activities сторонних приложений, поэтому
  ActivityKit там выключен и запись не делается.
- `wierdr-push` должен работать на том компьютере, к которому подключается телефон: он
  читает документ `wierdr-push` из своего ядра. Агенты с машин, добавленных в это ядро
  (`hc machine add`), в сводку попадают.
- Mac должен быть включён и не спать. Иначе активность через 25 мин показывает
  «Not updated», а закроется по таймауту ActivityKit.
- Если смахнуть активность (или переустановить приложение), она вернётся, когда откроешь
  Wierdr: приложение запишет в документ, что активности на телефоне нет, и демон снова
  пришлёт start на это устройство. Без открытия Wierdr она вернётся только со следующим
  стартом, после того как все агенты 20 с простояли и кто‑то снова начал работать.
- Сборки подписаны development‑профилем, значит окружение APNs — sandbox. Для
  TestFlight или App Store оно станет `production`. Приложение берёт окружение из
  профиля, демон держит запасной канал на каждое окружение.
- Бюджет пушей задаёт iOS. Priority 10 уходит только с alert, остальное идёт с priority 5,
  плюс `NSSupportsLiveActivitiesFrequentUpdates`.
