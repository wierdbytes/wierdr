# Допущения

1. **Mac доступен по SSH.** Remote Login включён (на этом Mac уже включён; sshd предлагает
   `publickey,password,keyboard-interactive`). iPad видит Mac в одной сети
   (`mentoair.local`) или через Tailscale (`mentoair-1`;
   iPad `ipad165` и iPhone `iphone-13-pro-max` уже в tailnet). Вне дома iPhone ходит к Mac
   только через Tailscale.
2. **herdr-core на Mac** установлен (`~/.local/bin/hc`, 0.1.20). Протокол — generation 1;
   проверено с hc 0.1.20 и удалённой машиной `lf` (0.1.14) через релей ядра Mac.
3. **Десктоп Herdr может работать одновременно** — Wierdr рассчитан именно на это: общий
   документ `herdr-app` правится только compare‑and‑swap’ом с валидацией (см. «Writes» в [architecture/model.md](../architecture/model.md)).
4. **Тема**: тёмная — Atom One Dark, светлая — Paper (как в `wierd-layout`); переключается
   системной темой iPad или вручную в Settings. Цвета спейсов берутся из `shared.json`
   десктопа; если его нет — по тому же правилу палитры. Статус done — зелёный темы
   (`#98c379` / `#1a7f37`, её ANSI green), а не синий, как в Herdr; марка blocked — красная
   точка, как у done, а не плашка «!»; working — жёлтая точка, а не спиннер; так же в
   Live Activity.
5. **iPad Pro 13" M4** зарегистрирован в команде разработчика `AUL4CCB2XY`
   (его UDID есть в профиле), поэтому сборку можно ставить сразу.
   **iPhone 13 Pro Max** (iOS 27.2.1,
   Developer Mode включён) — тоже в профиле команды. Минимальная версия — iOS/iPadOS 18.
