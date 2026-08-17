# Fedora LARBS — Runbook

See INSTALL.md for the linear step-by-step procedure. This file explains what the installer does, why each step
differs from upstream LARBS, and how to verify the result.

`fedora.sh` is a port of [LARBS](https://larbs.xyz) from Arch to Fedora 44. It
runs as root on a fresh minimal install, creates a user, installs the programs
in `progs.csv`, deploys the [voidrice fork](https://github.com/Net-Nezvanova/fedorice), and configures the
system so that logging in on tty1 starts dwm.

---

## 1. Prerequisites

| | |
|---|---|
| **Fedora** | 44 (43 should work; the installer reads `rpm -E %fedora` and does not hard-code a version) |
| **Install type** | Fedora Everything netinstall → **Minimal Install**, or Fedora Server minimal. No desktop, no display manager. |
| **Disk** | 30 GB. The Go toolchain, ~15 `-devel` packages, LibreWolf and full ffmpeg add up. |
| **RAM** | 4 GB. The ueberzugpp C++20 compile is the memory-hungry part; 2 GB fails confusingly. |
| **Network** | Required throughout. |

Do **not** run this on a machine you care about. It creates a user, rewrites
parts of `/etc`, and overwrites dotfiles.

---

## 2. Prepare the repositories (do this first)

The dotfiles must reach the target machine **through git**, never as a file
copy. Two things break otherwise, both silently:

- **CRLF line endings.** A shebang of `#!/bin/sh\r` fails with
  `bad interpreter: /bin/sh^M`. Every script in the repo dies.
- **Symlinks.** Six files are stored in git as symlinks (mode `120000`):
  `.zprofile`, `.xprofile`, `.xinitrc`, `.gtkrc-2.0`, `.config/sxiv`,
  `.local/share/bg`. A Windows checkout without `core.symlinks` materialises
  them as ordinary text files containing the target path. `~/.zprofile` as a
  regular file means the login profile never runs: no `$PATH`, no `$XINITRC`,
  no `startx`. You get a bare zsh prompt and nothing in any log explains it.

Verify before you publish the repo:

```sh
git -C voidrice ls-files -s | awk '$1=="120000"'   # must list all six
file voidrice/.local/bin/setbg                     # must NOT say "CRLF"
```

Then make it reachable from the target. Either push the `fedora` branch to a
git host, or hand-carry a bundle:

```sh
git -C voidrice bundle create /tmp/voidrice.bundle fedora
# copy the bundle to the target, then use its path as the -r argument
```

`-r` is optional. It defaults to `Net-Nezvanova/fedorice`, the Fedora dotfiles
this installer is built against, so a plain `./fedora.sh` is a complete install.
Pass `-r` only to deploy a different repository.

Do not point it at upstream voidrice: that repo is Arch-specific and deploying
it here produces a broken system. `fedora.sh` cannot detect this for you.

### One repository or two

`-r` points at whatever holds the **dotfiles**. The installer deploys a
repository by copying it over `$HOME`, so it needs to land on the directory that
contains `.config` and `.local` — not on a parent holding several projects.

**Two repositories** (the default assumption). Nothing extra:

```sh
./fedora.sh -r https://github.com/you/your-dotfiles.git
```

**One repository holding both**, e.g.

```
my-fedora-rice/
├── fedora-larbs/     fedora.sh, progs.csv, RUNBOOK.md
└── voidrice/         .config/, .local/, .zprofile, ...
```

then name the dotfiles subdirectory with `-d`, and the branch with `-b` if it
is not `fedora`:

```sh
./fedora.sh -r https://github.com/you/my-fedora-rice.git -d voidrice -b main
```

Without `-d` the copy would put `~/fedora-larbs/` and `~/voidrice/` into your
home and no dotfiles at all. The script checks for `.config` under whatever
`-r`/`-d` resolve to and stops with that suggestion rather than deploying
nonsense, but it is easier to pass the flag.

A third option is to put the dotfiles at the repository **root** and the
installer in a subdirectory. That works with a bare `-r` and no `-d`, but the
installer directory is then copied into `$HOME` too, so add it to the cleanup
list next to `.git` and `README.md` in the main body.

---

## 3. Get the installer onto the target

```sh
sudo dnf install -y git
git clone <your-fork> ~/fedora-larbs && cd ~/fedora-larbs
```

If you transfer `fedora.sh` any other way, check it first — the script also
self-tests for CR and refuses to run, but catching it earlier is cheaper:

```sh
file fedora.sh          # "POSIX shell script", not "with CRLF line terminators"
```

---

## 4. Dry run first

```sh
./fedora.sh -n -r <dotfiles-repo-url>
```

This resolves every row of `progs.csv` with `dnf repoquery`, every source
repository with `git ls-remote`, and the ueberzugpp build dependencies —
installing nothing and needing no root. It exits non-zero and lists anything it
could not resolve.

Run this on the actual target. Package names drift between Fedora releases, and
the dry run turns a 40-minute failure into a 30-second one. It is the single
highest-value step in this runbook.

---

## 5. Install

```sh
sudo ./fedora.sh -r <dotfiles-repo-url>            # dotfiles at the repo root
sudo ./fedora.sh -r <repo-url> -d voidrice -b main # one repo holding both
```

Four whiptail prompts (welcome, username, password, confirm), then it is
unattended. Everything is logged to `/var/log/fedora-larbs.log`; on failure the
script prints the tail of that log.

Reboot, log in as the new user on tty1, and the session starts by itself.

---

## 6. What it does, and why it differs from upstream

### Removed from upstream LARBS

| Upstream step | Why it is gone |
|---|---|
| `refreshkeys` (`archlinux-keyring`, `pacman-key`) | No Arch keyring. |
| AUR helper bootstrap (`yay` via `makepkg`) | No AUR. Source builds and pipx cover the gap. |
| `pacman.conf` / `makepkg.conf` edits | No analogue. |
| **`ln -sfT /bin/dash /bin/sh`** | **Unsafe on Fedora.** `bash` owns `/usr/bin/sh`, and Fedora's packaging guidelines explicitly permit bashisms in RPM scriptlets. Repointing `/bin/sh` can break arbitrary package transactions later. `dash` is still installable for your own scripts. |
| `dbus-uuidgen > /var/lib/dbus/machine-id` | systemd owns `/etc/machine-id`. |
| `readlink -f /sbin/init` branches | Fedora is always systemd. |
| `00-larbs-wheel-can-sudo` | Fedora's stock `/etc/sudoers` already has `%wheel ALL=(ALL) ALL` uncommented. Keeping it would just raise the question of which one is authoritative. |

### Changed

- **`useradd -m -G wheel,video`**, not Arch's `-g wheel`. Fedora uses user private
  groups; making `wheel` the *primary* group would leave every file the user
  creates group-owned by `wheel`. `video` is what brightnessctl's udev rule grants
  backlight control to, so without it the brightness keys do nothing on a laptop.
- **`usermod -s`**, not `chsh` — `chsh` lives in `util-linux-user`, which is
  not in `@core`, so upstream's call would silently do nothing.
- **chrony**, not `ntpd -q -g`, and it runs *before* any repository key import.
  A skewed clock on a fresh VM fails TLS and RPM signature checks in ways that
  look like network errors.
- **`newt`** is the first package installed. Fedora's whiptail is `newt`, not
  `libnewt`; without it every prompt is `command not found`.
- **Build dependencies are enumerated explicitly.** Fedora has no `base-devel`.
  `dnf group install "Development Tools"` gets you compilers but *not*
  `libX11-devel`, so dwm/st/dmenu would fail on `<X11/Xlib.h>`.
- **ffmpeg is swapped before anything else installs.** Fedora ships
  `ffmpeg-free` (no H.264/H.265/AAC encoders). Swapping on a clean slate avoids
  making the resolver unpick a large dependency web later.
- **`restorecon -RF /usr/local/bin /usr/local/share`** after every
  `make install`. SELinux is left enforcing. `/usr/local/bin` is `bin_t` and new
  files inherit it, so this is belt-and-braces — the real hazard is `mv` from
  `/tmp`, which preserves the source label. The recipes use `install`, never
  `mv`.
- **`99-touchpad.conf`**, not `40-libinput.conf`, and written *after* the
  package loop. `/etc/X11` does not exist on `@core` until the X server is
  installed, and Fedora already ships `/usr/share/X11/xorg.conf.d/40-libinput.conf`.
- **`fc-cache` and `update-desktop-database`** are run. Upstream runs neither;
  without the latter `xdg-open` cannot resolve the `.desktop` files just
  installed, which breaks `linkhandler` and `opout`.
- **sudoers drop-ins are validated.** `newperms()` refuses names containing a
  dot (sudo silently ignores them, and the only symptom is a build hanging on a
  password prompt with no terminal), sets mode `0440`, runs `visudo -cf` on the
  fragment and `visudo -c` on the whole tree, and removes the file if either
  fails.
- **Audio is enabled with `systemctl --global enable`.** You cannot
  `systemctl --user enable` for a user who has never logged in — there is no
  user bus and no `XDG_RUNTIME_DIR`. In practice Fedora already socket-activates
  pipewire; this just makes the intent explicit.

### Fixed while porting

Four upstream bugs, all inherited by every LARBS fork:

1. `installationloop` only strips `#` comments on the `curl` path, so a *local*
   `progs.csv` feeds its own header row to the installer.
2. The `while read` loop shares stdin with `make` and `git`, which can swallow
   CSV rows. Reading on fd 3 fixes it.
3. `/tmp/progs.csv` is a fixed path written by root in a world-writable
   directory. Now `mktemp`.
4. Every install is silenced to `/dev/null`, discarding all error output. Now
   logged, with failures collected and reported at the end instead of vanishing.

### Fixed after the first bare-metal attempt

The port was written against a Proxmox VM and worked there. Everything below is
a fault that only a real laptop exposes, because a VM's virtio NIC needs no
firmware, its default sink and backlight behave, and nobody reboots it from the
window manager.

1. **The bootstrap gap — the reason the first bare-metal install failed.**
   `progs.csv` correctly lists `NetworkManager-wifi` and the Intel firmware, but
   they cannot help: a Minimal install is `@core`, which has none of them, so a
   wifi-only laptop has no network on first boot and `fedora.sh` cannot run at
   all. No change to this repo's package list could ever have fixed that. It is
   closed at install time instead, by `ks/larbs-minimal.ks`.

   **Update, 2026-08-15:** putting the groups in `%packages` turned out not to be
   sufficient. On a T480s install, Anaconda accepted the kickstart intact and
   then committed a package set with `@hardware-support` and `git` removed — no
   error, no prompt — and the laptop booted with no wifi anyway. The kickstart
   now verifies its own result in `%post`, detects the wireless driver from
   sysfs, installs what is missing while the installer still has network, and
   escalates to `/etc/motd` if that fails. Read
   `/root/larbs-bootstrap.log` before rebooting out of the installer. See
   `INSTALL.md` → "Asking for the groups is not the same as getting them".
2. **`cronie` was never installed** but `crond` was enabled. It is in comps
   `standard`, not `core`, so on the documented Minimal install the unit did not
   exist and the enable failed silently — taking `cron/checkup` with it, and
   with it the status bar's update count.
3. **Every `NOPASSWD` rule for shutdown, reboot and poweroff was dead.** They
   were written as `/usr/sbin/...`; Fedora completed the `/usr` merge in 42, a
   user's `PATH` finds `/usr/bin/shutdown`, and sudo compares the resolved path
   literally. Now `/usr/bin/...`.
4. **No polkit authentication agent.** The `polkit` daemon was installed with
   nothing able to prompt, so every privileged action in `sysact` — shutdown,
   reboot, suspend, hibernate — failed silently from inside dwm. `lxpolkit` is
   now installed and autostarted (`polkit-gnome` no longer exists in Fedora).
5. **Source trees were built as root inside the user's home**, leaving
   root-owned `config.h` files that §8 of this document tells you to edit. Now
   compiled as the user, with only `make install` privileged.
6. **`checksymlinks` ran too late and checked too little.** It fired after the
   dotfiles were already copied into `$HOME`, so a bad repo aborted the install
   with packages and dotfiles in place but no sudoers rules, no touchpad config
   and no services. It now validates the staging clone before anything is
   copied, and covers all six symlinks rather than four.
7. **`QT_QPA_PLATFORMTHEME=gtk2` had no plugin behind it.** `qt5-qtstyleplugins`
   was missing, so every Qt program warned and fell back to Fusion.
8. **RPM Fusion free was gated on nonfree.** Both URLs went into one transaction
   probed only via the free URL, so an unreachable nonfree mirror disabled both
   and broke the ffmpeg swap — despite full ffmpeg living in free and nothing
   here needing nonfree at all.

### Fixed once the system was in daily use

Faults that only appear when someone actually looks at the bar, changes a
wallpaper, or reaches for a feature. Suckless changes are `sed` edits in
`patchsource()`, because the three programs are cloned from upstream and there
is no fork to hold them; script and config changes are in the dotfiles repo.

1. **Every status bar icon rendered as blank space.** Fedora's
   `google-noto-color-emoji-fonts` ships only `Noto-COLRv1.ttf`. FreeType
   composites COLRv0 and the bitmap colour formats but not COLRv1, so handed
   that face it draws the empty base outline — numbers appeared, icons did not.
   `progs.csv` already installed the monochrome font and dwm's `drw.c` already
   refused colour fonts in its *fallback* path; what was missing is that the
   *configured* font list still named `NotoColorEmoji` outright, and a
   configured font never reaches the fallback. Fixed in dwm, dmenu and st.

   `:color=false` is load-bearing and is not redundant with naming the
   monochrome family. `fc-match "Noto Emoji"` resolves straight back to the
   COLRv1 file, so the family name alone changes nothing — this was confirmed
   through `XftFontOpenName`, the same call dwm makes, before being relied on.

2. **st needed a second, separate fix.** Beyond the configured list, `x.c` has
   its own runtime path that searches every installed font for a glyph missing
   from both configured fonts, and it had no colour rejection at all — so it
   could pull the COLRv1 face back in regardless of config. It now sets
   `FC_COLOR`/`FcFalse` on that pattern, as dwm's `drw.c` already does. The
   `sed` is anchored on `fcpattern` so it cannot hit the unrelated `pattern`
   call in `xloadfonts`.

3. **The theme depended on who won a startup race.** dwm reads its colours from
   the X resource database exactly once at startup, and the pywal run inside
   `setbg` is what puts them there. `xprofile` backgrounded `setbg` and
   `xinitrc` execs dwm the moment `xprofile` returns; wal takes about a second,
   so dwm reliably came up with compiled-in colours and then switched to the
   wallpaper's palette on the next restart or `Mod+F5`. `xprofile` now waits.

4. **The bar failed WCAG AA on any low-saturation wallpaper.** Upstream points
   both `normfgcolor` and `selbgcolor` at `color4`, which pywal fills with a
   mid-tone sampled from the image. Measured on a muted wallpaper, `color4`
   `#3B7683` on `color0` `#191c2f` is **3.29:1** — status text and window title
   both. `normfgcolor` now takes `color7`, pywal's designated light-foreground
   slot for every image, measuring **9.86:1**. `selbgcolor` takes `color6`,
   giving **5.31:1** for the title bar. Note that lightening the title *text*
   instead is not the fix: `color7` on `color4` measures 3.00:1, worse, because
   a mid-tone accent contrasts poorly in both directions — the accent itself
   has to move.

   `selbordercolor` takes `color7` as well. Upstream's `color8` is pywal's
   "bright black", grey by construction — `#64687b` here, **3.05:1** against
   the unfocused border, so the focused window barely stood out. `color6` was
   tried first and measured 5.31:1, but it only *tends* to be bright: `color1`
   through `color6` are image samples and a wallpaper can invert the ordering.
   `color7` is the slot pywal reserves for the light foreground, so it is near
   10:1 on any image. The trade is that focus is no longer one teal signal —
   the title bar stays `color6` while the border goes near-white. That is
   acceptable because `normbordercolor` is `color0`, identical to the root
   background: an unfocused window shows no border at all, so there is nothing
   for a bright one to clash with, and the border is the only focus cue left
   when the bar is hidden or a float sits over another tag's title.

5. **The wifi indicator was permanently blank.** `sb-internet` read link
   quality from `/proc/net/wireless`, part of the Wireless Extensions API the
   kernel dropped in favour of nl80211. The `awk` matched nothing, so the block
   rendered as a bare ethernet ❎ — indistinguishable from being offline while
   the wifi was up. It now uses `iw`, which reads from the driver in about 2ms
   against ~22ms for the `nmcli` equivalent and does not require
   NetworkManager; `nmcli` remains a fallback. Signal arrives in dBm rather
   than the old 0–70 scale, so it is mapped linearly and clamped. Adds `iw` to
   `progs.csv`.

6. **There was no Bluetooth front end at all.** The stack works — `bluez`,
   an nl80211-era adapter and PipeWire's bluez5 codecs including LDAC — but
   nothing drove it. Nothing packaged fits either: `bluetuith` is not in
   Fedora's repos, and blueman's tray applet needs a systray patch this dwm
   does not carry. `dmenubluetooth` drives `bluetoothctl` directly, bound to
   `Mod+Shift+B` (the placeholder upstream leaves commented out) and documented
   in the `Mod+F1` manual. Adds `bluez` to `progs.csv`.

   Pairing runs in a floating terminal rather than silently: it is the one
   operation that can demand a passkey or a confirmation, and those prompts
   have to be answerable. `rfkill` is checked first, because a blocked adapter
   makes every `bluetoothctl` call fail as though no device existed.

7. **`Mod+F1` — the LARBS manual — did nothing.** It pipes `groff -Tpdf` into
   zathura, but Fedora splits `gropdf` and the `devpdf` font files out of
   `groff` into `groff-perl`, which nothing installed. `-Tps` worked, `-Tpdf`
   died with `cannot load 'DESC' description file for device 'pdf'`, and the
   keybinding failed silently. Adds `groff-perl` to `progs.csv`.

8. **The clock was 12-hour.** Now `%H:%M`. The icon still derives from `%I`,
   because there are only twelve clock-face emoji and it tracks the 12-hour
   position regardless of how the time is printed.

9. **st's transparency was on but invisible.** Not a bug — upstream's
   `alpha = 0.8` composites correctly (the alpha patch is in the fork, `x.c`
   requests a 32-bit ARGB visual, and `xprofile` starts `xcompmgr`), it is just
   too near opaque to read as an effect. Sampling the framebuffer inside an st
   window returned `#22263D`/`#31364D` rather than a flat `color0` `#191c2f`,
   confirming the pipeline worked before any change. Now `0.75`, with
   `alphaOffset = 0.1` so an unfocused terminal fades a further step into the
   wallpaper — a second focus cue alongside the border above, and free, since
   the compositor is already running. `Alt+a`/`Alt+s` adjust the running
   instance in 0.05 steps; both values are also readable from Xresources as
   `alpha` and `alphaOffset`.

   Anchor these seds on the identifiers, not on `0.8`/`0.0`. An upstream
   default change would otherwise skip the edit silently and st would come back
   opaque with nothing in the log to say why.

   **The blend is additive, which is worth knowing before turning alpha down
   further.** XRender source colours are premultiplied, and `xloadalpha` sets
   `dc.col[defaultbg].color.alpha` without scaling the RGB to match, so the
   composite is not `α·bg + (1−α)·wallpaper` but

   ```
   result = bg + (1 − α) · wallpaper
   ```

   The background is only ever *added to*. Verified against the framebuffer at
   five coordinates, comparing a focused and an unfocused st over a known
   wallpaper — every channel landed within one 8-bit step of that formula and
   several were exact. Over a dark wallpaper it is indistinguishable from
   normal blending; over a bright one the terminal background rises instead of
   staying put. On the brightest region of the sample wallpaper (`#E3DCCC`) the
   focused background reaches `#525362` and `color7` text on it measures
   **4.44:1** — essentially at the AA line — and an unfocused window reaches
   `#686976` and **3.18:1**. Both are acceptable at these values, and unfocused
   text is not being read, but the margin is why alpha stops at 0.75 rather
   than going lower.

   Diagnosing this needs the border as ground truth. `xdotool windowfocus` does
   not reliably move dwm's focus — dwm re-asserts its own selected client — so
   a screenshot pair labelled from the xdotool calls alone can come out
   reversed. Read `selbordercolor` out of the image instead and label from
   that.

Not fixed, and deliberately so: the fingerprint reader. The T480s ships a
Synaptics `06cb:009a`, and `libfprint` 1.94 does not support it — its
compiled device table carries 33 Synaptics IDs from `0x00bd` to `0x01a4`, and
`0x009a` falls below the entire range, so `fprintd` would install and report no
device. The only route is the third-party `python-validity`, which is not
packaged for Fedora. It would also not unlock the screen: `slock` links
`libcrypt` and not `libpam`, so it reads the shadow hash directly and has no
PAM path for fingerprint to enter through.

---

## 7. Post-install checklist

In dependency order — each step assumes the previous one passed.

```sh
1.  log in as the new user on tty1; the shell is zsh
2.  ls -l ~/.zprofile ~/.xprofile ~/.xinitrc   # all three must be symlinks
3.  X starts automatically; if not, run `startx` and read
    ~/.local/share/xorg/Xorg.0.log  (not /var/log)
4.  keyboard and mouse work inside dwm
5.  echo $DBUS_SESSION_BUS_ADDRESS              # contains $XDG_RUNTIME_DIR/bus
6.  pgrep -c wireplumber                        # exactly 1
7.  systemctl --user show-environment | grep DISPLAY
8.  wpctl set-volume @DEFAULT_AUDIO_SINK@ 50%   # audio responds
9.  status bar populates, including the 📦 package count
10. dmenupass masks input  → proves Luke's dmenu fork is the one on PATH
11. maimpick takes a screenshot
12. lf shows an image preview (or a chafa rendering — see limitations)
13. mounter sees a USB stick
14. librewolf → about:policies → the four extensions are listed
15. sudo ausearch -m AVC -ts boot                # no SELinux denials
16. sudo ss -lntp | grep 9091                    # nothing; the system
                                                 # transmission unit is disabled
```

Step 10 is the one people skip. Fedora ships a vanilla `dmenu` that lacks the
`-P` flag `dmenupass` needs; if it ever shadows the fork, every
password-requiring action in the session fails without a message.

---

## 8. Customisation

**The status bar.** dwmblocks reads its module list from
`~/.local/src/dwmblocks/config.h`, which comes from Luke's repo. The installer
already renames `sb-pacpackages` to `sb-dnfpackages` there and drops the mail
and RSS modules. To change it further:

```sh
cd ~/.local/src/dwmblocks
$EDITOR config.h
sudo make install && sudo restorecon -RF /usr/local/bin
pkill -HUP dwm      # or just restart the session
```

The `restorecon` matters — skip it and SELinux may see a mislabelled binary.

**CPU temperature.** `sb-cpu` needs `sudo sensors-detect --auto` once. Its awk
pattern matches `Core 0`, which is Intel; AMD reports `Tctl`. Edit the script
if your bar shows nothing.

**Wallpaper.** `setbg <file>` or `setbg <directory>`. It regenerates the pywal
scheme and refreshes dwm.

**Adding packages.** Append rows to `progs.csv` and re-read the tag table at the
top of that file. Anything that lives only in RPM Fusion needs the `F` tag so
you get a clear error instead of `No match for argument`.

---

## 9. Third-party sources and trust decisions

Two, stated plainly because they are the only code entering the system from
outside Fedora's repositories:

1. **RPM Fusion** release packages are installed with `--nogpgcheck`. Their
   signing key is not trusted until the package that ships it is installed, so
   this is the documented bootstrap — but it does mean the first two RPMs are
   taken on faith over TLS.
2. **LibreWolf** is installed from `repo.librewolf.net`, with `gpgcheck` on as
   the repo file configures it.

A third, of a different kind: **xcape is vendored** in `vendor/xcape/`, because
its upstream repository was deleted outright. The source is Debian's packaged
1.2 rather than a surviving GitHub fork — see `vendor/xcape/PROVENANCE.md`. It
is committed here precisely so the install depends on nothing third-party at
run time, and so the code that runs on every login is auditable in this repo.

**No COPRs are used.** That is deliberate — the main nsxiv COPR is already dead
(404), and now so is xcape's upstream. That is exactly the failure mode a
third-party repository dependency invites. A
consequence worth knowing: `dnf5-plugins` is never needed, because
`dnf config-manager` is never called. The moment you reach for `dnf copr
enable`, you will need that package and you will have left the sourcing policy
behind.

---

## 10. Recovery and troubleshooting

**The log.** `/var/log/fedora-larbs.log` has every command's output. Failures
are also collected and shown in the final dialog.

**Killed mid-run.** The temporary passwordless-sudo drop-in is removed by an
`EXIT` trap, but `kill -9` bypasses traps. Check and clean up:

```sh
ls /etc/sudoers.d/larbstemp && sudo rm -f /etc/sudoers.d/larbstemp
```

**All sudo broken.** A malformed sudoers fragment breaks the recovery path too.
`newperms()` validates before installing to prevent this, but if it happens,
boot with `systemd.unit=rescue.target` and remove the file in
`/etc/sudoers.d/`.

**X starts but nothing responds to input.** `xorg-x11-drv-libinput` and
`mesa-dri-drivers` are *weak* dependencies of the X server, and minimal installs
often disable weak deps. They are explicit rows in `progs.csv` for this reason;
confirm with `rpm -q xorg-x11-drv-libinput`.

**Notifications intermittent, keyring prompts never appear.** A second D-Bus
session bus. Check `echo $DBUS_SESSION_BUS_ADDRESS` points into
`$XDG_RUNTIME_DIR`, and that nothing reintroduced `dbus-launch` into
`.config/x11/xinitrc`.

**Re-running the installer overwrites dotfiles.** `putgitrepo` copies over
`$HOME` unconditionally, so any local edit to a tracked file is lost. Back up
first:

```sh
tar caf ~/dotfiles-backup-$(date +%F).tar.gz ~/.config ~/.local/bin
```

---

## 11. Known limitations

- **Image previews may be text.** ueberzugpp is built from source and that build
  is deliberately non-fatal — losing previews is much better than losing the
  whole install. If it failed, `lf` falls back to chafa's terminal rendering,
  and `lfub` detects the missing binary and starts plain `lf` rather than
  hanging on a FIFO that nothing is reading. Check with `command -v ueberzug`.
- **Already-mounted phones may still be listed.** `jmtpfs` reports a single
  `jmtpfs` filesystem name in `/etc/mtab` rather than a per-device one, so the
  "already mounted" filter in `mounter` is best-effort. Mounting twice fails
  harmlessly.
- **The country flag depends on a name match.** `sb-iplocate` asks
  `ifconfig.co/country` for a full country name and looks it up in
  `~/.local/share/larbs/chars/emoji`. If your country's spelling differs there,
  the flag is blank. This replaced `geoiplookup`, whose Fedora data has been
  frozen since 2018 and would have answered confidently and wrongly.
- **`sent` and `pass` are not installed.** `compiler`, `opout` and `otp`
  reference them; those code paths are guarded by `ifinstalled` and simply do
  nothing. Add them to `progs.csv` if you want them.
- **No mail, RSS or calendar.** Dropped by choice. Restoring them means adding
  neomutt, mutt-wizard (from git — it is not packaged), newsboat and calcurse,
  and restoring the `sb-mailbox` and `sb-news` modules and their `config.h`
  entries.
