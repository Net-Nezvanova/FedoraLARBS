# FedoraLARBS

A port of [LARBS](https://larbs.xyz) — Luke Smith's dwm/st/dmenu desktop — from
Arch to **Fedora 44**.

`fedora.sh` runs as root on a fresh minimal install, creates a user, installs
the programs listed in `progs.csv`, deploys the dotfiles, and configures the
system so that logging in on tty1 starts dwm. No display manager, no desktop
environment.

> **Do not run this on a machine you care about.** It creates a user, rewrites
> parts of `/etc`, and overwrites dotfiles.

---

## Two repositories

This is the part that surprises people, so it is worth stating first.

| Repository | Holds | Deployed by |
|---|---|---|
| **FedoraLARBS** (this one) | the installer: `fedora.sh`, `progs.csv`, the kickstart, the vendored `xcape` | run by hand |
| **[fedorice](https://github.com/Net-Nezvanova/fedorice)** (branch `fedora`) | the dotfiles: `.config/`, `.local/bin/`, the status bar scripts | cloned by `fedora.sh` |

The suckless programs live in **neither**. `progs.csv` clones `dwm`, `st`,
`dmenu` and `dwmblocks` from Luke Smith's upstream repositories, so there is no
fork here to hold local changes to their `config.h`. Everything this port needs
to change in them is applied as a `sed` edit in `fedora.sh`'s `patchsource()`
function, immediately after the clone and before `make`.

That is a deliberate trade: `sed` anchors survive upstream churn better than
context-matched `.patch` files against a shallow clone, and it keeps the whole
port in one readable script. It does mean **any change you make to a suckless
`config.h` by hand will be lost on the next install** unless it also goes into
`patchsource()`.

---

## Quick start

```sh
# on a fresh Fedora 44 Minimal Install, as root
git clone https://github.com/Net-Nezvanova/FedoraLARBS.git
cd FedoraLARBS/fedora-larbs
./fedora.sh -n          # dry run: resolve every package, install nothing
./fedora.sh             # the real thing
```

`-r` points at a different dotfiles fork, `-b` at a different branch, `-p` at a
different package list. `./fedora.sh -h` lists them all.

**Read `INSTALL.md` before doing this on a laptop.** A wifi-only machine
installed from Fedora Minimal has no network on first boot and cannot run the
installer at all; `ks/larbs-minimal.ks` exists to close that gap, and it has to
be used at install time, not after.

### Requirements

| | |
|---|---|
| **Fedora** | 44 (43 should work — the version is read from `rpm -E %fedora`, never hard-coded) |
| **Install type** | Everything netinstall → Minimal Install, or Server minimal |
| **Disk** | 30 GB |
| **RAM** | 4 GB — the ueberzugpp C++20 compile is the hungry part; 2 GB fails confusingly |
| **Network** | required throughout |

---

## Documentation

| File | What it is |
|---|---|
| **`INSTALL.md`** | The linear procedure for a real machine, start to finish, including the wifi trap and first-login troubleshooting. |
| **`RUNBOOK.md`** | What the installer does and why each step differs from upstream. §6 is the full record of deviations and fixes; §11 lists known limitations. |
| **`vendor/xcape/PROVENANCE.md`** | Where the vendored `xcape` came from and why it is vendored (upstream was deleted). |

---

## How it differs from upstream LARBS

`RUNBOOK.md` §6 is the authoritative list with the reasoning for each. In brief:

**Removed** — everything Arch-specific: the keyring refresh, the AUR helper
bootstrap, `pacman.conf`/`makepkg.conf` edits, the `dbus-uuidgen` machine-id,
and the `/bin/sh` → `dash` symlink (actively unsafe on Fedora, where `bash` owns
`/usr/bin/sh` and packaging guidelines permit bashisms in RPM scriptlets).

**Changed** — Fedora's user private groups, `usermod -s` instead of a `chsh`
that is not in `@core`, chrony before any key import, explicit build
dependencies because there is no `base-devel`, an early `ffmpeg` swap off
`ffmpeg-free`, `restorecon` after every `make install` with SELinux left
enforcing, and validated sudoers drop-ins.

**Fixed** — four upstream bugs inherited by every LARBS fork (comment stripping
on the local-`progs.csv` path, a `while read` loop sharing stdin with `make`,
a fixed `/tmp/progs.csv` path, and every install silenced to `/dev/null`), then
a round of faults only a real laptop exposes, then a round only daily use
exposes:

| Symptom | Cause |
|---|---|
| Every status bar icon blank | Fedora ships emoji as COLRv1 only, which FreeType cannot composite |
| Blank emoji in st specifically | a second, separate font-fallback path in `x.c` with no colour rejection |
| Theme differed between boots | dwm reads Xresources once at startup and lost a race with pywal |
| Bar text below WCAG AA | upstream maps two roles to `color4`, a mid-tone on muted wallpapers |
| Wifi indicator permanently blank | `/proc/net/wireless` was removed with Wireless Extensions |
| No Bluetooth anything | the stack works; nothing drove it, and nothing packaged fits |
| `Mod+F1` silently did nothing | Fedora splits `gropdf` into `groff-perl` |
| Everything tiny on a laptop panel | DPI pinned at 96, and upstream's fonts mix `size=` with `pixelsize=` so it cannot just be raised |
| Korean tofu, Chinese and Japanese fine | no CJK font installed at all; the accidental dependency covering Han and kana has no Hangul |

---

## Keys worth knowing immediately

`Mod` is the Super key, and **Caps Lock is remapped to Super** (tapped alone it
is Escape). The full list is `Mod+F1`.

| | |
|---|---|
| `Mod+Enter` | terminal |
| `Mod+d` | dmenu |
| `Mod+w` / `Mod+W` | browser / `nmtui` |
| `Mod+B` | Bluetooth menu |
| `Mod+F4` | pulsemixer |
| `Mod+F5` | re-read Xresources (reload the palette) |
| `Mod+Backspace` | lock, logout, reboot, shutdown |
| `Alt+Shift+K` / `J` | terminal zoom in / out (`Alt+Shift+Home` resets) |
| `Alt+a` / `Alt+s` | terminal transparency up / down |

---

## Known limitations

`RUNBOOK.md` §11 has the full list. The one most likely to matter:

**The fingerprint reader does not work, and cannot be made to.** The T480s
ships a Synaptics `06cb:009a`; `libfprint` 1.94's device table runs from
`0x00bd` to `0x01a4` and `0x009a` falls below it entirely, so `fprintd` installs
cleanly and reports no device. The only route is the third-party
`python-validity`, which Fedora does not package. It would not unlock the screen
in any case — `slock` links `libcrypt`, not `libpam`.

---

## Licence

The installer follows upstream LARBS. Vendored `xcape` keeps its own licence;
see `vendor/xcape/LICENSE`.
