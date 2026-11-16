# Справочник CLI и рабочего стола

[English](CLI.md) · **Русский** · [К описанию проекта](../README.ru.md)

## Команды

| Команда | Что делает |
|---|---|
| `hwe install` | поставить пакеты и раскатать конфиги на **эту** машину |
| `hwe update [--check]` | подтянуть репозиторий и привести машину в соответствие |
| `hwe uninstall` | откатить симлинки конфигов и login-shell |
| `hwe theme <list\|apply\|pick\|validate\|current\|sddm>` | сгенерировать цвета всех компонентов из темы |
| `hwe wall <list\|set\|random\|pick\|current\|restore>` | обои — сгенерированные темой или свои |
| `hwe power` | меню сессии с подтверждением действий питания |
| `hwe keys` | шпаргалка, генерируемая из зарегистрированных биндов (`SUPER+/`) |
| `hwe clip <show\|wipe>` | история буфера обмена (`SUPER+C`) |
| `hwe record <toggle\|region>` | запись экрана → `~/Videos` |
| `hwe screenshot <screen\|region\|file\|annotate>` | скриншоты с сообщениями об успехе, отмене и ошибке |
| `hwe sunset <toggle\|on\|off\|status>` | ночной свет |
| `hwe checkconfig [--notify]` | проверить Lua-конфиг и ошибки Hyprland |
| `hwe vm <up\|ssh\|console\|status\|list\|down\|destroy\|rebuild>` | управление локальной VM |
| `hwe doctor [host\|vm\|--report]` | проверить машину или готовность хоста к VM |
| `hwe session <save\|restore\|list\|clear>` | именованные снимки рабочего стола |
| `hwe version` | показать версию |

## Именованные снимки сессий

```bash
hwe session save 1       # сохранить все окна и workspace в слот 1
hwe session restore 1    # восстановить эту сессию
hwe session list         # имена, даты и размеры снимков
hwe session clear 1      # удалить один снимок
hwe session clear --all  # удалить все снимки (с подтверждением)
```

Снимок охватывает каждое отображаемое окно, workspace и монитор, включая активный workspace
и геометрию тайловых окон. Восстановление использует уже открытые приложения, запускает
недостающие и применяет положения через Lua layout provider, не делая окна плавающими.
Текущие окна не закрываются. Автоматического сохранения или восстановления нет.

Снимки живут в `~/.local/state/hwe/sessions/`, записываются атомарно с правами `0600`.
Заголовки окон, PID и аргументы командной строки не сохраняются. Внутреннее состояние
приложений остаётся задачей самих приложений, а не снимка.

## Темы

Тема — это **один** файл `themes/<name>/theme.toml`: приватная `[palette]` и семантический
контракт `[sem]`. Шаблоны в `templates/*.j2` читают **только роли**, поэтому новая тема
сводится к одному `theme.toml`.

```bash
hwe theme list                # доступные темы (текущая помечена *)
hwe theme apply mocha         # рендер + деплой + живой reload всех компонентов
hwe theme pick                # rofi-галерея с превью (SUPER+SHIFT+T)
hwe theme validate <name>     # проверить тему на контракт
```

Picker показывает все двенадцать тем спокойной галереей 4×3 из графических карточек.
**Enter** применяет выбранную тему, **Escape** отменяет выбор без изменений. Для своих тем
без `preview.png` карточка создаётся в кеше; если генерация невозможна, есть текстовый fallback.

Таблица `[font]` задаёт семейство и размеры шрифта для каждой поверхности. `theme apply`
рендерит цвета в Hyprland, Waybar, Kitty, Rofi, Mako, GTK 3/4, Kvantum, Starship, kdeglobals
и Hyprlock; затем перечитывает запущенные приложения и ставит обои темы. SDDM синхронизируется
отдельно командой `hwe theme sddm`.

**Готовые темы:** `amethyst` · `default` · `ember` · `frost` · `garden` · `mocha` ·
`mono` · `neon` · `paper` · `linen` · `rust` · `void`.
Добавить свою — см. [Руководство по темам](../themes/README.ru.md).

## Обои

```bash
hwe wall pick                 # rofi с миниатюрами (SUPER+SHIFT+W)
hwe wall random [theme]       # случайные обои темы
hwe wall set <path|name>      # конкретный файл или имя из `wall list`
```

Каждая тема несёт сгенерированные обои `wallpaper.png`. Свои фото/GIF клади в
`~/.config/hwe/themes/<name>/wallpapers/`; старый путь внутри checkout тоже поддерживается.

`awww` показывает статические изображения и анимированные GIF. В `mono` есть бесшовная
шестисекундная анимация. В Ubuntu, где `awww` не упакован, hyprwe использует `hyprpaper`
и статические обои. Hyprlock и SDDM всегда получают отдельное статическое изображение.

## Структура репозитория

```text
bin/                 CLI hwe и сборщик проверенного cloud-образа Ubuntu
lib/                 реализация установки, обновлений, тем, сессий, VM и команд desktop
provision/           cloud-init, общий установщик, skeleton личного слоя и SDDM
pkg/                 списки пакетов, карта Ubuntu и lock-файл шрифтов
themes/<name>/       theme.toml, сгенерированные обои и карточка темы
templates/           Jinja-шаблоны на основе семантических ролей темы
config/              XDG-конфиги, симлинкуемые в ~/.config
scripts/             генераторы тем, обоев, превью и модулей Waybar
tests/               pytest и Bats
justfile             задачи разработки
```

## Команды разработки

```bash
just            # список задач
just up         # = hwe vm up
just check      # всё, что проверяет CI: линтеры + тесты
just test       # только тесты: pytest + bats
just lint       # shellcheck по всем shell-скриптам
just fmt        # shfmt (4 пробела; не гейт)
just walls      # перегенерировать обои
just previews   # перегенерировать превью тем
just gallery    # пересобрать assets/themes.png и assets/social-preview.png
```

Гейты качества ставятся вместе со всем остальным через `hwe install`, и CI ставит ровно их же.
Воркфлоу разработки описан в [CONTRIBUTING.ru.md](../CONTRIBUTING.ru.md).
