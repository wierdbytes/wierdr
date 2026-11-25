# Документация Wierdr

Оглавление: файл — о чём. Один файл — одна тема, до ~15 KB. Оглавление файла —
`grep -n '^#' <файл>` (в `features/` темы — пункты `- **…**`: `grep -n '^- \*\*' <файл>`).

## `features/` — что реализовано

- [overview.md](features/overview.md) — что такое Wierdr, скриншоты, архитектура кратко
- [connection.md](features/connection.md) — хосты, SSH, вход по ключу и паролю, ключ хоста, настройка
  хоста, переподключение, автоподключение, демо
- [sidebar.md](features/sidebar.md) — сайдбар: список снизу вверх, шапка, ширина и оверлей на iPad
- [agents-panel.md](features/agents-panel.md) — панель агентов: кольцо статусов, ⌘P, поиск
- [sidebar-spaces.md](features/sidebar-spaces.md) — машины, карточки спейсов, перетаскивание спейсов
- [sidebar-rows.md](features/sidebar-rows.md) — строки: вид, порядок, закреплённые, нажатие, свайпы,
  меню, «прочитано»
- [sidebar-subagents.md](features/sidebar-subagents.md) — сабагенты, фоновая работа Claude Code,
  окно сабагента
- [panel.md](features/panel.md) — терминальная панель iPad: таб‑бар, «+», панели, терминал,
  клавиатура, поле сообщения, ввод пальцами
- [structure.md](features/structure.md) — новые спейсы и табы, сплиты, закрытие, переименование
- [shortcuts.md](features/shortcuts.md) — горячие клавиши
- [iphone.md](features/iphone.md) — раскладка iPhone: первый экран, экран панели, баннер,
  Live Activity
- [iphone-input.md](features/iphone-input.md) — ввод на iPhone: поле сообщения, клавиатура, панель
  клавиш, размер текста
- [tour.md](features/tour.md) — тур по приложению: вид, карточка, сценарии iPhone и iPad

## `tradeoffs/` — решения и их цена

- [assumptions.md](tradeoffs/assumptions.md) — допущения: Mac по SSH, версия hc, десктоп рядом,
  тема, устройства
- [app.md](tradeoffs/app.md) — эмулятор терминала, шрифты, иконки, размер терминала, картинки, фон,
  демо, раскладка iPhone
- [connection.md](tradeoffs/connection.md) — SSH, пароль, known hosts
- [services.md](tradeoffs/services.md) — Live Activity, релей пушей, лендинг, демон wierdrd,
  интеграции агентов из приложения
- [desktop.md](tradeoffs/desktop.md) — «сиротские» терминалы, мёртвые панели, мод‑панели десктопа,
  перетаскивание спейсов и табов
- [agents-pi.md](tradeoffs/agents-pi.md) — pi: данные агента, сабагенты, сессии
- [agents-claude-code.md](tradeoffs/agents-claude-code.md) — Claude Code: данные, заголовок,
  фоновая работа, строка сабагента
- [agents-codex.md](tradeoffs/agents-codex.md) — Codex: данные, статус, заголовок
- [sidebar.md](tradeoffs/sidebar.md) — один сайдбар на iPad и iPhone, статусы в шапке
- [agents-panel.md](tradeoffs/agents-panel.md) — панель агентов
- [sidebar-list.md](tradeoffs/sidebar-list.md) — список, плавность прокрутки, меню строк
- [iphone-input.md](tradeoffs/iphone-input.md) — iPhone: терминал, клавиатура, поле сообщения,
  свайпы и тапы по терминалу
- [iphone-sidebar.md](tradeoffs/iphone-sidebar.md) — iPhone: сайдбар, движение, список под одну
  руку, строки, дерево агента, баннеры
- [iphone-device.md](tradeoffs/iphone-device.md) — iPhone: экран, установка по воздуху и по tailnet,
  автоподключение, узкое окно iPad
- [ipad-input.md](tradeoffs/ipad-input.md) — iPad: ввод пальцами, колонка клавиш, поле сообщения
- [ipad-tab-bar.md](tradeoffs/ipad-tab-bar.md) — iPad: таб‑бар — вид, названия, ширины, меню и
  перетаскивание таба, кнопка сайдбара
- [tour.md](tradeoffs/tour.md) — тур: стиль, состав, тексты, оверлей, где и когда, сценарий iPad
- [tested.md](tradeoffs/tested.md) — что проверено, а что нет
- [plans.md](tradeoffs/plans.md) — ближайшие планы

## `architecture/` — устройство (EN)

- [overview.md](architecture/overview.md) — схема, слои (пакеты, релей, лендинг, интеграции),
  правила, сборка
- [app.md](architecture/app.md) — `App/Sources` по папкам, сквозной тест в симуляторе
- [app-sidebar.md](architecture/app-sidebar.md) — `App/Sources/Sidebar/`
- [model.md](architecture/model.md) — `WierdrModel`: файлы движка, запись в документ, демо, факты,
  тесты

## Отдельные темы

- [BUILD.md](BUILD.md) — сборка, установка, устройства, симуляторы, WDA
- [ssh.md](ssh.md) (EN), [hc-protocol-client.md](hc-protocol-client.md) (EN) — связь с herdr-core
- [live-activity.md](live-activity.md) — Live Activity и APNs
- [relay.md](relay.md) — релей пушей (Cloudflare Worker, App Attest)
- [wierdrd.md](wierdrd.md) — демон на Mac, формула Homebrew, выпуск
- [host-setup.md](host-setup.md) — лист «Set Up <хост>»: демон и интеграции агентов
- [pi.md](pi.md), [claude-code.md](claude-code.md), [codex.md](codex.md) — интеграции агентов
- [site.md](site.md) — лендинг `wierdr.workat.dev`
- [app-store.md](app-store.md) — план публикации в App Store
- `research/` — исследования: `ui-spec.md`, `herdr-app-model.md` (EN; код ссылается на их
  разделы `§N`), `push-relay.md`, `claude-subagent-session.md`, `pi-agents.md`
- `screenshots/` — снимки экрана
