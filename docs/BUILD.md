# Сборка и установка Wierdr

Требования: Xcode 27 (проект генерируется XcodeGen и уже лежит в репозитории как
`Wierdr.xcodeproj`), сертификат Apple Development команды `AUL4CCB2XY` —
есть в связке ключей этого Mac. iPad Pro 13" M4 и
iPhone 13 Pro Max уже зарегистрированы в
команде и входят в профиль, которым подписывается сборка (один `.ipa` для обоих).

## Установка на iPhone

На iPhone уже включён Режим разработчика (iOS 27.2.1). Три способа, любой:

1. **По воздуху, без кабеля** (iPhone в tailnet, Mac включён):
   ```sh
   make ipa && scripts/ota.sh   # dist/Wierdr.ipa + страница установки
   ```
   На iPhone открой в Safari **https://<mac>.<tailnet>.ts.net/wierdr/** → «Установить» →
   приложение появится на экране «Домой». Страницу раздаёт `tailscale serve` (путь `/wierdr`,
   только tailnet) через локальный `python3 http.server` на 127.0.0.1:8791.
   Выключить: `scripts/ota.sh off`.
2. **Кабелем или по Wi‑Fi** (iPhone в Xcode › Devices, разблокирован):
   ```sh
   make install-iphone          # Release-сборка, установка через devicectl и запуск
   ```
   или `xcrun devicectl device install app --device <UDID> dist/Wierdr.ipa`.
3. Xcode: открыть `Wierdr.xcodeproj`, выбрать iPhone, Run.

Если iOS пишет, что разработчик не доверенный: **Настройки › Основные › VPN и управление
устройством › Apple Development: … › Доверять**.

Дальше в Wierdr на iPhone: **Add Host** → дома `mentoair.local`, вне дома по Tailscale
`mentoair-1` (или `100.x.y.z`), пользователь `mentor`, вход **Password** → Connect,
подтвердить отпечаток (см. «Подготовка Mac»), потом **Settings → Install This iPhone’s Key on …**.
iOS спросит доступ к локальной сети — разреши (для `mentoair.local`).

## Установка на iPad

1. Подключи iPad кабелем USB‑C к Mac, разблокируй, нажми **Доверять**.
2. На iPad: **Настройки › Конфиденциальность и безопасность › Режим разработчика** → вкл.
   (iPad перезагрузится; подтверди после загрузки). Нужно один раз.
3. На Mac:
   ```sh
   cd ~/me/dev/wierdr
   make install      # Release-сборка, подпись, установка через devicectl и запуск
   ```
   - Другой вариант: открыть `Wierdr.xcodeproj` в Xcode, выбрать iPad и нажать Run.
     Xcode один раз спросит про плагин SwiftTerm — «Trust & Enable».
   - Готовый файл: `dist/Wierdr.ipa` (development‑подпись) — перетащить на iPad в
     Xcode › Window › Devices and Simulators, или
     `xcrun devicectl device install app --device <UDID> dist/Wierdr.ipa`.
4. Если iOS пишет, что разработчик не доверенный: **Настройки › Основные › VPN и управление
   устройством › Apple Development: … › Доверять**.

После первой установки по кабелю можно включить **Connect via network** для iPad в
Xcode › Devices and Simulators — дальше `make install` работает по Wi‑Fi.

Debug‑сборка: `make install CONFIG=Debug` (парсинг вывода терминала в Debug ~7× медленнее).

## Подготовка Mac

1. **Системные настройки › Основные › Общий доступ › Удалённый вход** — вкл.
   (на этом Mac уже включено).
2. herdr-core установлен (`~/.local/bin/hc`, ставится вместе с Herdr).
3. В Wierdr добавь хост:
   - адрес: `mentoair.local` (та же Wi‑Fi), `192.168.x.y` или через Tailscale
     `mentoair-1` / `100.x.y.z`;
   - пользователь: `mentor`, порт 22;
   - вход: **Password** для первого раза. Потом в Settings нажми
     **Install This iPad’s Key on …** — Wierdr допишет свой ключ в `~/.ssh/authorized_keys`
     и переключит хост на вход по ключу. Либо скопируй публичный ключ из редактора хоста
     (Copy/Share) и добавь в `~/.ssh/authorized_keys` сам.
4. Первое подключение спросит про ключ хоста. Отпечаток ED25519 этого Mac:
   `SHA256:YKysidsqfwHmxS7eFJTAbqVwmY2mQ33PdJtS4S4XXFs`
   (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`).
5. iOS спросит разрешение на доступ к локальной сети — разреши (для адресов в LAN).

## Проверка на iPad: скриншоты и управление

`scripts/ipad.sh` снимает экран физического iPad, тапает, печатает и читает дерево
доступности Wierdr. Окно Herdr на Mac для сравнения снимает `herdr-app shot <file.png>`
(см. `~/.config/herdr-app/AGENTS.md`); скрипт к Herdr не привязан.

Один раз на iPad: **Настройки › Разработчик › Enable UI Automation**. Если включить уже
после `start`, перезапусти WDA: `scripts/ipad.sh stop && scripts/ipad.sh start`.

```sh
make install                        # свежая сборка на iPad
scripts/ipad.sh start               # WebDriverAgent на iPad + проброс :8100 по USB (iproxy)
scripts/ipad.sh shot /tmp/ipad.png  # скриншот iPad (devicectl)
scripts/ipad.sh tree                # дерево элементов с рамками в точках (1600×1200 в landscape)
scripts/ipad.sh tap "Quick Switcher" # тап по accessibility label
scripts/ipad.sh tap-xy 800 336      # тап по точке; long-press, swipe x1 y1 x2 y2
scripts/ipad.sh type lazy           # ввод в поле/терминал с фокусом клавиатуры
scripts/ipad.sh orient portrait     # повернуть экран (devicectl)
scripts/ipad.sh stop
```

- WebDriverAgent (appium) клонируется и собирается при первом `start` в
  `~/.local/share/WebDriverAgent` с командой `AUL4CCB2XY` и bundle id
  `pw.xff.WebDriverAgentRunner`. Логи и pid лежат в `$TMPDIR/wierdr-wda/`.
- Сессия WDA цепляется к приложению на переднем плане и не перезапускает Wierdr.
  Перезапуск приложения: `scripts/ipad.sh launch`.
- Скриншот iPad — 3200×2400 px (2× от точек).
- При запуске WDA iPadOS может спросить код-пароль iPad: так система подтверждает UI
  Automation. Отключить запрос можно только вместе с код-паролем. Разрешение живёт
  от нескольких часов до нескольких дней, а запрос появляется только на `start`: запросы к
  уже запущенному WDA пароль не спрашивают. Запускай WDA один раз на рабочую сессию и
  останавливай `stop`, когда закончил.
- `type` печатает туда, где фокус клавиатуры. Если фокус в терминале, текст уйдёт
  в живую сессию.

## Проверка в симуляторе iPhone

`scripts/iphone-sim.sh` — то же, что `ipad.sh`, для симулятора «Wierdr iPhone 13 Pro Max»
(создаётся при первом `boot`): сборка и установка, запуск с аргументами, скриншоты,
WebDriverAgent на порту 8200 (iPad‑овский остаётся на 8100) для тапов/свайпов/ввода.

```sh
make sim-iphone                         # сборка + симулятор + демо
scripts/iphone-sim.sh start             # WebDriverAgent в симуляторе (один раз за сессию)
scripts/iphone-sim.sh launch -demo YES  # (-open pane|banner|switcher|settings — сразу туда)
scripts/iphone-sim.sh tap "Agents"      # по accessibility label; tap-xy в точках (428×926)
scripts/iphone-sim.sh swipe 2 500 300 500   # свайп назад от края
scripts/iphone-sim.sh type "echo hi"
scripts/iphone-sim.sh shot /tmp/iphone.png
scripts/iphone-sim.sh orient landscape; scripts/iphone-sim.sh appearance dark
```

Живое подключение из симулятора — как в `docs/architecture.md` (тестовый sshd на
127.0.0.1:2222, `SIMCTL_CHILD_WIERDR_AUTOCONNECT=…`), с `SIM` = «Wierdr iPhone 13 Pro Max».
Осторожно: открытая на iPhone панель забирает размер своего терминала и на Mac; для проверок
создавай свой спейс (`WIERDR_DEBUG_STEPS='sleep 4;newSpace'`) и закрывай его после.

## Другие цели

```sh
make test       # unit-тесты WierdrKit на macOS
make sim        # симулятор iPad Pro 13" (M4)
make sim-iphone # симулятор iPhone 13 Pro Max, демо
make install-iphone  # Release на подключённый iPhone
make ipa        # dist/Wierdr.ipa (iPad и iPhone); scripts/ota.sh — страница установки по воздуху
make project    # перегенерировать Wierdr.xcodeproj из project.yml
python3 scripts/gen-assets.py   # пересобрать Icons.xcassets из Design/icons
```

Живые тесты (против ядра на этом Mac; пишут только в отдельный документ и свои временные
терминалы):

```sh
cd Packages/WierdrKit
WIERDR_LIVE=1 swift test          # HerdrCore + WierdrModel
WIERDR_SSH_LIVE=1 swift test --filter HerdrSSHTests
```

`scripts/test-sshd.sh start|stop` — одноразовый sshd на `127.0.0.1:2222` для тестов
симулятора, не трогает `~/.ssh`. Сквозной прогон в симуляторе — см. `docs/architecture.md`.
