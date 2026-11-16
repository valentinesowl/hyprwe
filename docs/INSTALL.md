# Installation and updates

**English** · [Русский](INSTALL.ru.md) · [Back to the project](../README.md)

## Installation

The installer adds packages, deploys the configs and sets up the login screen. It does so
**reversibly**, preserving whatever is already on the machine.

```bash
# 1. Clone the repository (a minimal system has no git yet:
#    sudo pacman -S git  /  sudo apt install git)
git clone https://github.com/valentinesowl/hyprwe.git ~/hwe
cd ~/hwe

# 2. Switch to a TTY (Ctrl+Alt+F2) and roll hyprwe out onto this machine.
#    The installer refuses to start from a graphical session: it touches the
#    compositor, the bar and the login shell — not something to do under a running Hyprland.
./bin/hwe install
```

What `hwe install` does:

- installs `pkg/core.lst` + `pkg/dev.lst` from the distribution's repositories (on Ubuntu
  the names go through `pkg/map/apt.map`); on Arch, `paru` is bootstrapped if `pkg/aur.lst`
  is non-empty — AUR entries are skipped on Ubuntu, with a notice;
- symlinks `config/*` into `~/.config`, **keeping** your previous configs beside them as `*.hwe-bak`;
- generates and applies the default theme (`mocha`);
- makes `zsh` the login shell and enables NetworkManager + SDDM (the login screen).

After the install `hwe` is linked into `/usr/local/bin/hwe` — from then on you just call
`hwe …` (before the install — `./bin/hwe …`). The first login greets you and points at
`SUPER + /`, the keybinding cheatsheet.

Configs are deployed as **symlinks** into the repository: edit `~/hwe/config/...` and the
change is live right away. Settings of your own belong in `~/.config/hwe/` instead — see
[Customization](CUSTOMIZATION.md).

## GPU

Intel/AMD work out of the box — mesa comes along with Hyprland, the drivers are in-tree.
**NVIDIA** is detected by the installer via `lspci` and set up for you — on Arch only; on
Ubuntu it says so and leaves the GPU alone. The setup covers the driver (open modules for
Turing+, proprietary for older cards), DRM modesetting, initramfs modules and a pacman
rebuild hook. That touches boot, so it asks for confirmation.

**This path has not yet been tried on live NVIDIA hardware** (development happened on Intel).
`HWE_NO_NVIDIA=1` skips it entirely; `HWE_NVIDIA_DRIVER=<package>` pins the driver if the
generation detection guessed wrong. `hwe uninstall` does **not** roll that layer back
(initramfs/modules).

## Safety and opt-outs

- **A system upgrade is opt-in on a real machine.** The full upgrade (`pacman -Su` /
  `apt-get upgrade`) runs only with `HWE_FULL_UPGRADE=1` or in an unattended VM. Otherwise
  the install works against the current package database (on Ubuntu the package lists are
  still refreshed — apt needs that before any install).
- **Opt-outs:** `HWE_NO_ZSH=1` (leave the shell alone), `HWE_NO_NM=1` (leave networking alone),
  `HWE_NO_NVIDIA=1` (leave the GPU alone), `HWE_FORCE=1` (run even from a graphical session —
  at your own risk).
- **Unattended:** `HWE_ASSUME_YES=1` answers yes to every confirmation (install preflight,
  NVIDIA, package sync, VM teardown). It deliberately does **not** cover the PPA compositor
  consent (`HWE_HYPR_SOURCE=ppa`).
- **Rollback:** `hwe uninstall` restores your previous configs from `*.hwe-bak` and offers to
  revert the login shell (it asks first); packages and services stay in place.
- Minor knobs: `NO_COLOR=1` disables colour output; `HWE_DEFAULT_THEME=<name>` sets which
  theme the install applies (default `mocha`).

## Ubuntu

Lua-only hyprwe targets **Ubuntu 27.04 experimentally** and requires **Hyprland 0.57.0 or
newer** (0.57.2 is recommended). **Ubuntu 26.04 is not supported by hyprwe 2.x**: its archive
candidate is 0.53.3, so installation stops before packages, configs, shell or services are
changed. For Hyprland 0.53–0.56, use the hyprwe 1.4.x `legacy-conf` line instead.

**Where the compositor comes from is your decision, and hyprwe will not make it quietly.**

| `HWE_HYPR_SOURCE` | Requirement | What you grant |
|---|---|---|
| `repo` *(default)* | Ubuntu's candidate must be >= 0.57.0 | nothing new — the machine already trusts its distribution |
| `ppa` | the explicit third-party candidate must also be >= 0.57.0 | a stranger's signing key, confined by apt pinning to the Hyprland stack |

```bash
hwe install                        # use Ubuntu's candidate, after the version gate
HWE_HYPR_SOURCE=ppa hwe install    # explicitly opt in to the third-party archive
```

A PPA is not assumed to contain a suitable release: hyprwe checks its candidate after updating
the package metadata and refuses it if it is too old. Adding a third-party archive ordinarily
hands its key the right to install *any* package; hyprwe pins it to the compositor stack alone.
Setting `HWE_HYPR_SOURCE=ppa` **is** the consent and is not covered by `HWE_ASSUME_YES`.
Building the compositor from source is not offered, and hyprwe never switches sources to make
the version check pass.

Ubuntu packages can enable systemd *user* units on installation. hyprwe starts the session
programs from `config/hypr/autostart.lua`, so duplicate packaged units are stood down.
Other package availability differences are recorded in `pkg/map/apt.map`; the map must be
revalidated against Ubuntu 27.04 before that target is declared stable.

## Keeping a machine in sync

```bash
hwe update            # pull the repo and reconcile this machine
hwe update --check    # read-only: report drift, change nothing
hwe doctor            # same read-only check (bare doctor = doctor host)
hwe doctor vm         # host prerequisites for the VM workflow instead
hwe doctor --report   # the same check as one paste-ready block for an issue
```

`hwe update` pulls with `--ff-only` and stops if the tree is dirty or the history has
diverged — it will never silently merge or stash your work. Then it relinks the configs,
re-applies the current theme and offers to install packages that are missing from the
lists. `hwe doctor` reports the same drift without touching anything: config symlinks,
packages, the personal layer, login shell, Hyprland config errors and the screen-sharing
stack (pipewire, wireplumber, the portals). Detection and repair share the install primitives,
so a check cannot drift from what the installer actually lays down.
