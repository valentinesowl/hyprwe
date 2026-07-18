# Hyprland Workstation Environment (HWE)

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Arch Linux](https://img.shields.io/badge/Arch_Linux-1793D1?logo=archlinux&logoColor=white)](https://archlinux.org)
[![Hyprland](https://img.shields.io/badge/Hyprland-58E1FF?logo=hyprland&logoColor=black)](https://hyprland.org)
[![Release](https://img.shields.io/github/v/release/valentinesowl/hyprwe)](../../releases/latest)
[![CI](https://github.com/valentinesowl/hyprwe/actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

**Рабочее окружение на Arch, которое ставится одной командой, собирается одинаково на
одноразовой виртуалке и на твоём железе — и в котором приятно проводить день.**

Arch даёт полный контроль, но окружение под него собираешь сам: композитор, бар, лаунчер,
уведомления, шрифты, темы, экран входа. Десятки конфигов, которые один раз доводишь до ума —
а на новой машине собрать заново уже не помнишь как. HWE берёт эту сборку на себя и, что
важнее, делает её **повторимой**: всё окружение описано в репозитории, а `hwe install` на
железе и `hwe vm up` на одноразовой виртуалке разворачивают его из одного источника.

И это не «рабочая станция» — а спокойное, цельное место и для работы, и
для повседневности. Цвета, геометрия и шрифты всех компонентов рендерятся из **одного**
файла-палитры: тот же приём, что даёт повторимость, красит весь стек в один тон — без
крикливости и визуального шума.

HWE пригодится, если ты хочешь Arch для повседневности и работы, но не знаешь, с чего начать;
не хочешь тратить вечера на конфиги; или уже всё настроил руками — и не можешь это воспроизвести.

Три столпа проекта:

1. **Единый движок тем** — цвета всех компонентов рендерятся из **одного** файла-палитры
   (`themes/<name>/theme.toml`), без ручного дублирования. `hwe theme apply` меняет вид
   всего рабочего стола живьём.
2. **Модульный конфиг Hyprland** — hyprland + kitty + waybar + rofi + mako + hyprlock +
   hypridle, собранный на `source`-инклудах и заложенный под рост.
3. **Dev-VM в одну команду** — поднимает Arch-виртуалку через `libvirt`/`virt-install`
   (видна в **virt-manager**), провижинит её **полностью автоматически** через
   `cloud-init` и разворачивает **выбранную локальную ветку git** — без пуша на GitHub.

<p align="center">
  <img src="assets/themes.png" alt="встроенные темы HWE" width="100%">
  <br>
  <em>Десять встроенных тем (восемь тёмных + две светлые: <code>paper</code> и мягкая <code>linen</code>) — каждая это один <code>theme.toml</code>, из которого рендерится весь стек.</em>
</p>

---

## Установка

Превратить свою Arch-машину в HWE — одна команда. Установщик ставит пакеты, раскатывает
конфиги и настраивает вход в систему; делает это **обратимо** и не трогает то, что ему не
принадлежит.

```bash
# 1. Склонировать репозиторий
git clone https://github.com/valentinesowl/hyprwe.git ~/hwe
cd ~/hwe

# 2. Выйти в TTY (Ctrl+Alt+F2) и раскатать HWE на эту машину.
#    Из графической сессии установщик откажется стартовать: он трогает композитор,
#    бар и login-shell — это не делается из-под работающего Hyprland.
./bin/hwe install
```

Что делает `hwe install`:

- ставит `pkg/core.lst` + `pkg/dev.lst` (официальные repo); `paru` бутстрапится, только
  если `pkg/aur.lst` непустой;
- симлинкует `config/*` в `~/.config`, **сохраняя** твои прежние конфиги рядом как `*.hwe-bak`;
- генерирует и применяет тему по умолчанию (`mocha`);
- делает `zsh` login-шеллом и включает сервисы: NetworkManager + SDDM (экран входа).

**GPU.** Intel/AMD работают из коробки — mesa приезжает вместе с Hyprland, драйверы
in-tree, настраивать нечего. **NVIDIA** установщик определяет по `lspci` и настраивает сам:
драйвер (open-модули для Turing+, проприетарный для старых карт), DRM-modeset, модули в
initramfs и pacman-хук пересборки. Это трогает загрузку, поэтому спрашивает подтверждение —
и, честно: **эта ветка пока не проверена на живом NVIDIA-железе** (разработка шла на Intel).
`HWE_NO_NVIDIA=1` пропускает её целиком; `HWE_NVIDIA_DRIVER=<пакет>` фиксирует драйвер, если
детект поколения промахнулся. Откат `hwe uninstall` этот пласт (initramfs/модули) **не** трогает.

Осторожно и предсказуемо:

- **Полного обновления системы по умолчанию нет.** `pacman -Su` — только по
  `HWE_FULL_UPGRADE=1`; иначе установка идёт против текущей БД пакетов, без коварного
  одиночного `-Sy`.
- **Опт-ауты:** `HWE_NO_ZSH=1` (не трогать shell), `HWE_NO_NM=1` (не трогать сеть),
  `HWE_NO_NVIDIA=1` (не трогать GPU), `HWE_FORCE=1` (не отказываться в графической сессии — на свой страх).
- **Откат:** `hwe uninstall` снимает симлинки и возвращает shell из `*.hwe-bak`; пакеты и
  сервисы не сносит — заблокировать себя нельзя.

После установки `hwe` линкуется в `/usr/local/bin/hwe` — дальше зовёшь просто `hwe …` (до
установки — `./bin/hwe …`). Первый вход поздоровается и подскажет `SUPER + /` — шпаргалку по
горячим клавишам.

> Конфиги деплоятся **симлинками** на репозиторий: правишь `~/hwe/config/...` — изменения
> сразу живые.

---

## CLI: `hwe`

| Команда | Что делает |
|---|---|
| `hwe install` | поставить пакеты и раскатать конфиги на **эту** машину |
| `hwe uninstall` | откатить симлинки конфигов и login-shell (пакеты/сервисы остаются) |
| `hwe theme <list\|apply\|pick\|validate\|current\|sddm>` | сгенерировать цвета всех компонентов из темы |
| `hwe wall <list\|set\|random\|pick\|current\|restore>` | обои (сгенерированные темой или свои фото) |
| `hwe power` | rofi-меню сессии (lock/logout/suspend/reboot/shutdown) |
| `hwe keys` | шпаргалка по горячим клавишам (rofi, генерится из биндов; `SUPER+/`) |
| `hwe clip <show\|wipe>` | история буфера обмена (cliphist, rofi; `SUPER+C`) |
| `hwe record <toggle\|region>` | запись экрана (wf-recorder → `~/Videos`; индикатор в баре) |
| `hwe checkconfig [--notify]` | показать ошибки конфига из запущенного Hyprland |
| `hwe vm <up\|ssh\|console\|status\|list\|down\|destroy\|rebuild>` | локальная dev-VM (libvirt + cloud-init) |
| `hwe doctor` | проверить готовность хоста к VM-воркфлоу |
| `hwe version` | показать версию (из `bin/hwe`) |

---

## Темы

Тема — это **один** файл `themes/<name>/theme.toml`: приватная `[palette]` и семантический
контракт `[sem]` (~19 ролей: `bg_*`, `fg_*`, `accent`, `red`/`green`/…, `border`, `urgent`).
Шаблоны в `templates/*.j2` читают **только роли**, а не сырую палитру, так что новая тема
не требует правок конфигов.

```bash
hwe theme list                # доступные темы (текущая помечена *)
hwe theme apply mocha         # рендер + деплой + живой reload всех компонентов
hwe theme pick                # rofi-галерея с превью (SUPER+SHIFT+T)
hwe theme validate <name>     # проверить тему на контракт (fail-loud)
```

Отдельная таблица `[font]` — тоже контракт: семейство шрифта и размеры под каждую
поверхность (`terminal`/`bar`/`launcher`/`notify`/`gtk`), с дефолтами-fallback. Меняешь
размер шрифта прямо в теме — см. [`themes/README.md`](themes/README.md#типографика-font).

`theme apply` рендерит цвета в hyprland, waybar, kitty, rofi, mako, GTK 3/4, Kvantum (Qt/KDE),
starship, kdeglobals и hyprlock; затем перечитывает запущенные приложения и ставит обои темы.
Гритер SDDM синхронизируется отдельно (нужен root): `hwe theme sddm`.

**Готовые темы:** `amethyst` · `default` · `ember` · `frost` · `garden` · `mocha` (по
умолчанию) · `neon` · `paper` (светлая) · `linen` (мягкая светлая) · `void`. Добавить свою — см.
[`themes/README.md`](themes/README.md).

### Обои

```bash
hwe wall pick                 # rofi с миниатюрами (SUPER+SHIFT+W)
hwe wall random [theme]       # случайные обои темы
hwe wall set <path|name>      # конкретный файл или имя из `wall list`
```

Каждая тема несёт **сгенерированные обои** `wallpaper.png` (собственные, без лицензий):
процедурный арт в одном из шести стилей — см. `themes/README.md`.
Свои фото клади в `themes/<name>/wallpapers/` (в `.gitignore`) — они появятся рядом с ними.

---

## Конфиг Hyprland

Точка входа — `config/hypr/hyprland.conf`, которая только подключает модули:

| Файл | За что отвечает |
|---|---|
| `colors.conf` | **генерируется** `hwe theme` (`$accent`, …) |
| `environment.conf` | env сессии + `$mainMod`, `$terminal`, `$launcher` |
| `monitors.conf` | мониторы и масштаб |
| `appearance.conf` | general / decoration / blur / анимации |
| `theme.conf` | **генерируется** — рамка, скругления, прозрачность из темы |
| `input.conf` | клавиатура (us/ru), тачпад, жесты |
| `keybindings.conf` | горячие клавиши (SUPER; фокус на стрелках; без дублей) |
| `windowrules.conf` | правила окон и слоёв |
| `autostart.conf` | автозапуск (waybar, mako, hyprpaper, polkit, трей…) |

Плюс `hypridle.conf` (idle → лок/DPMS) и `hyprlock.conf` (генерируется). При каждом входе
`hwe checkconfig --notify` показывает на экране ошибки синтаксиса, если Hyprland поменял грамматику.

**Основные бинды:**
`SUPER+T` терминал · `SUPER+N` файлы · `SUPER+B` браузер · `SUPER+R` лаунчер (rofi) ·
`SUPER+Q` закрыть · `SUPER+V` плавающее · `SUPER+F` фуллскрин · `SUPER+←↑↓→` фокус ·
`SUPER+SHIFT+←↑↓→` двигать окно · `SUPER+1..0` воркспейсы · `SUPER+S` scratchpad ·
`SUPER+L` / `SUPER+Escape` лок · `SUPER+Space` раскладка us↔ru ·
`SUPER+SHIFT+T` тема · `SUPER+SHIFT+W` обои · `SUPER+SHIFT+E` меню питания ·
`SUPER+/` шпаргалка биндов · `SUPER+C` буфер обмена · `SUPER+SHIFT+C` цветопипетка ·
`SUPER+ALT+R` / `SUPER+ALT+S` запись экрана (весь / область) ·
`Print` скриншот экрана → буфер · `SHIFT+Print` область → буфер ·
`SUPER+Print` область → `~/Pictures` ·
`SUPER+SHIFT+Print` / `SUPER+P` область с аннотацией (satty) → `~/Pictures`.

---

## Песочница и разработка (VM)

Хочешь пощупать HWE, ничего не меняя на своей системе, — или разрабатывать сам HWE?
`hwe vm up` поднимает **одноразовую** Arch-виртуалку (видна в virt-manager) и разворачивает
в ней **твою локальную ветку git** — без пуша на GitHub. Внутри отрабатывает тот же
`hwe install`, что и на железе, так что это честная репетиция установки.

```bash
# 0. Проверить хост (libvirtd, группы, сеть, KVM)
./bin/hwe doctor

# 1. Убедиться, что есть коммит (VM разворачивает ветку из локального git)
git add -A && git commit -m "wip"        # если ещё не коммитили

# 2. Поднять VM с текущей веткой (или указать конкретную)
./bin/hwe vm up
./bin/hwe vm up feature-x

# 3. Зайти внутрь (когда cloud-init отработает)
./bin/hwe vm ssh
./bin/hwe vm console      # или смотреть загрузку в virt-manager
./bin/hwe vm status       # состояние + IP

# 4. Пересобрать начисто / снести
./bin/hwe vm rebuild
./bin/hwe vm destroy
```

Логин в VM: пользователь **`hwe`**, пароль **печатается при `vm up`** (случайный
per-build, а не хардкод). Твои `~/.ssh/id_*.pub` прокидываются в госта автоматически —
обычно вход по ключу, а пароль остаётся только для консоли.

Конфиги в VM деплоятся **симлинками** на репозиторий, так что правки в `~/hwe/config/...`
видны сразу — удобно для разработки самого HWE.

### Как это работает

1. `hwe vm up <branch>` качает Arch cloud-образ в `~/.cache/hwe/` (один раз) и
   **сверяет его GPG-подпись** с закреплённым fingerprint'ом arch-boxes.
2. Делает `git bundle` выбранной ветки и кладёт на **NoCloud seed ISO** (`xorriso`).
3. `virt-install --import` создаёт **libvirt-домен** (виден в virt-manager).
4. `cloud-init` в госте: создаёт юзера, монтирует seed, `git clone` из бандла,
   запускает `hwe install` — машина готова, полностью без ручного ввода.

### Переопределения (env)

| Переменная | Дефолт | Назначение |
|---|---|---|
| `HWE_VM_NAME` | `hwe-dev` | имя домена libvirt |
| `HWE_VM_MEMORY` | `4096` | RAM, МиБ |
| `HWE_VM_VCPUS` | `4` | vCPU |
| `HWE_VM_DISK_SIZE` | `24G` | размер корневого диска |
| `HWE_VM_USER` | `hwe` | имя пользователя в госте |
| `HWE_VM_PASSWORD` | *случайный* | пароль (задать, чтобы зафиксировать) |
| `HWE_LIBVIRT_URI` | `qemu:///system` | URI libvirt (дефолт virt-manager) |
| `HWE_VM_NETWORK` | `default` | имя libvirt-сети |
| `HWE_IMAGE_URL` | Arch cloudimg | базовый qcow2 |

---

## Структура репозитория

```
hyprwe/
├── bin/hwe                 # единый CLI: vm · install · theme · wall · power · keys · clip · record · checkconfig · doctor
├── lib/
│   ├── common.sh           # логирование, confirm, need, run
│   ├── vm.sh               # virt-install + cloud-init + git-bundle
│   ├── theme.sh            # hwe theme — рендер палитры во все компоненты
│   ├── wall.sh             # hwe wall — обои (per-theme, живой swap)
│   ├── power.sh            # hwe power — rofi-меню сессии
│   ├── keys.sh             # hwe keys — шпаргалка биндов (rofi)
│   ├── clip.sh             # hwe clip — история буфера (cliphist)
│   ├── record.sh           # hwe record — запись экрана (wf-recorder)
│   ├── checkconfig.sh      # hwe checkconfig — ошибки конфига Hyprland
│   └── welcome.sh          # hwe welcome — приветствие при первом входе
├── provision/
│   ├── cloud-init/         # user-data.tmpl, meta-data.tmpl (токены @@VAR@@)
│   ├── guest-install.sh    # ставит пакеты + деплоит конфиги (в госте и на железе)
│   ├── sddm/hwe/           # QML-гритер SDDM (тема из активной палитры)
│   ├── hyprland-uwsm.desktop  # сессия Hyprland (uwsm) для SDDM
│   └── arch-boxes.asc      # пиннинг ключа подписи cloud-образа
├── pkg/                    # core.lst · dev.lst · vm.lst · aur.lst
├── themes/<name>/          # theme.toml (палитра + [sem]) + wallpaper.png + preview.png
├── templates/              # .j2 — из [sem] рендерятся colors всех компонентов
├── config/                 # XDG-конфиги → симлинкуются в ~/.config
│   ├── hypr/               # модульный Hyprland (см. hyprland.conf)
│   ├── waybar/ rofi/ mako/ kitty/ gtk-3.0/ gtk-4.0/ zsh/
│   └── starship.toml
├── scripts/                # render-theme.py · genwall.py · genpreview.py · wbstat.py
├── tests/                  # pytest (движок тем, генераторы, гигиена репо) + bats/ (bash)
├── .github/workflows/      # ci.yml (гейты на PR) · release.yml (тег vX.Y.Z → релиз)
├── CHANGELOG.md            # версия живёт в bin/hwe; тег и CHANGELOG сверяются в CI
└── justfile                # dev-задачи (just up / ssh / check / walls …)
```

## Разработка

```bash
just            # список задач
just up         # = hwe vm up
just check      # всё, что проверяет CI: линтеры + тесты (см. CONTRIBUTING.md)
just test       # только тесты: pytest + bats
just lint       # shellcheck по всем скриптам
just fmt        # shfmt (4 пробела; не гейт)
just walls      # перегенерировать обои всех тем
just previews   # перегенерировать превью тем (для rofi-галереи)
just gallery    # пересобрать assets/themes.png из превью
```

Гейты качества ставятся вместе со всем остальным через `hwe install` (`pkg/dev.lst`), и CI
ставит ровно их же — так что зелёный `just check` локально означает зелёный пайплайн.
Как контрибьютить — [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Статус

`v1.0.0` — первый стабильный релиз: VM-воркфлоу, установщик, движок тем (10 тем),
SDDM-гритер, zsh. Дальше: больше компонентов панели, воркфлоу и полировка.

## Благодарности

Вдохновлено собственной системой автора для AwesomeWM и проектом
[HyDE](https://github.com/HyDE-Project/HyDE) — спасибо ему за идеи.

## Лицензия

[GPL-3.0](LICENSE) © 2026 valentinesowl.

Обои и превью тем (`themes/*/wallpaper.png`, `themes/*/preview.png`) сгенерированы
скриптами репозитория и распространяются под той же лицензией. Личные фото из
`themes/*/wallpapers/` в поставку не входят (см. `.gitignore`).
