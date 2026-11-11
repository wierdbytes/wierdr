# Сборка и установка Wierdr

Требования: Xcode 27 (проект генерируется XcodeGen и уже лежит в репозитории как
`Wierdr.xcodeproj`), сертификат Apple Development команды `AUL4CCB2XY` —
есть в связке ключей этого Mac. iPad Pro 13" M4 уже
зарегистрирован в команде и входит в профиль, которым подписывается сборка.

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
доступности Wierdr. Для сравнения он же снимает окно Herdr на Mac.

Один раз на iPad: **Настройки › Разработчик › Enable UI Automation**. Если включить уже
после `start`, перезапусти WDA: `scripts/ipad.sh stop && scripts/ipad.sh start`.

```sh
make install                        # свежая сборка на iPad
scripts/ipad.sh start               # WebDriverAgent на iPad + проброс :8100 по USB (iproxy)
scripts/ipad.sh both /tmp/cmp       # /tmp/cmp-ipad.png (devicectl) и /tmp/cmp-mac.png (herdr-app shot)
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
- Скриншот iPad — 3200×2400 px (2× от точек), Herdr на Mac — в физических пикселях окна.
  `herdr-app shot` работает без разрешения на запись экрана, даже если окно перекрыто.
- При запуске WDA iPadOS может спросить код-пароль iPad: так система подтверждает UI
  Automation. Отключить запрос можно только вместе с код-паролем. Разрешение живёт
  от нескольких часов до нескольких дней, а запрос появляется только на `start`: запросы к
  уже запущенному WDA пароль не спрашивают. Запускай WDA один раз на рабочую сессию и
  останавливай `stop`, когда закончил.
- `type` печатает туда, где фокус клавиатуры. Если фокус в терминале, текст уйдёт
  в живую сессию.

## Другие цели

```sh
make test       # unit-тесты WierdrKit на macOS
make sim        # симулятор iPad Pro 13" (M4)
make ipa        # dist/Wierdr.ipa
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
