# Installing on a real machine — step by step

A linear, self-contained procedure. `RUNBOOK.md` next to this file explains
*why* each choice was made; this file just tells you what to do.

Two repositories are involved:

| | |
|---|---|
| **Installer** | `https://github.com/Net-Nezvanova/FedoraLARBS` (branch `main`) — this repo |
| **Dotfiles** | `https://github.com/Net-Nezvanova/fedorice` (branch `fedora`) |

---

## 0. Before you wipe the machine

This erases the disk. Copy off anything you want to keep:

- SSH keys (`~/.ssh`), GPG keys
- Browser bookmarks and passwords
- Documents, photos, anything in the user profile
- **Any local clone of these two repos that has commits you have not pushed.**
  Check with `git status` and `git log origin/main..HEAD` in each. If either
  has unpushed work, push it now — it is the only copy.

Also make sure you can reach the internet during the install. On a laptop, use
an **ethernet cable if you have one**. The netinstall ISO downloads everything,
and configuring wifi in the installer is more fiddly than plugging in a cable.
If you must use wifi, the installer's network screen can do it — just do that
step first.

---

## 1. Make the installer USB

Download the Fedora **Everything netinstall** ISO (~800 MB):

<https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/iso/>

Take the file named `Fedora-Everything-netinst-x86_64-44-*.iso`. Not Workstation,
not Server, not the full Everything DVD.

Write it to a USB stick with [Fedora Media Writer](https://fedoraproject.org/workstation/download),
Rufus, or balenaEtcher. On Linux, `dd if=<iso> of=/dev/sdX bs=4M status=progress oflag=sync`.

Boot the laptop from it — usually F12, F2, Del or Esc during power-on. Secure
Boot can stay enabled; nothing here needs unsigned kernel modules.

---

## 2. Install Fedora

In the installer (Anaconda), do these **in this order**:

1. **Network & Host Name** — turn the connection **ON**. It defaults to off, and
   a netinstall cannot fetch a single package without it. Set the hostname if
   you like. Do this first or later steps will fail confusingly.
2. **Installation Destination** — pick the disk. Accept automatic partitioning
   unless you have a reason not to. If you are reclaiming space from an existing
   OS, this is where you delete those partitions.
3. **Software Selection** — **Minimal Install**. This matters. Anything larger
   installs a desktop that will fight with dwm.
4. **Root Account** — enable it and set a password.
5. **User Creation** — **skip it entirely.** `fedora.sh` creates your user
   itself, with the right groups and shell. Creating one here just leaves a
   half-configured account lying around.

Begin installation, then reboot and remove the USB.

---

## 3. Run the installer

Log in at the text console as **root**.

```sh
dnf install -y git
git clone https://github.com/Net-Nezvanova/FedoraLARBS.git
cd FedoraLARBS/fedora-larbs
```

**Dry run first.** It installs nothing, needs no root, and takes about half a
minute. It resolves every package name against your actual Fedora release,
which is what turns a 40-minute failure into a 30-second one:

```sh
./fedora.sh -n -r https://github.com/Net-Nezvanova/fedorice.git -b fedora
```

Every line should say `ok`. Warnings about optional ueberzugpp build
dependencies are fine — image previews fall back to chafa. Anything reported as
`MISS` needs fixing in `progs.csv` before continuing.

**Then install:**

```sh
./fedora.sh -r https://github.com/Net-Nezvanova/fedorice.git -b fedora
```

No `sudo` — you are root, which is what it expects.

You will be asked for a username, a password, and a confirmation. After that it
runs unattended for a while: it enables RPM Fusion and the LibreWolf repo,
installs about 100 packages, and builds dwm, dwmblocks, st, dmenu, xcape, lf and
ueberzugpp from source.

Everything is logged to `/var/log/fedora-larbs.log`. At the end it lists
anything that failed. **Read that list** — see §6 below.

---

## 4. First login

Reboot. Log in as your new user at the console on **tty1**.

The graphical session starts on its own — that is `.config/shell/profile`
running `startx` when it sees you are on tty1.

### The keys you need immediately

The modifier is **Super**, and Caps Lock is remapped to Super, so Caps works as
the modifier too (that is deliberate, and handy).

| Keys | Does |
|---|---|
| `Super` + `Return` | open a terminal |
| `Super` + `d` | dmenu — run any program |
| `Super` + `F1` | **the full keybinding guide** |
| `Super` + `q` | close the focused window |
| `Super` + `Shift` + `q` | logout / shutdown menu |
| `Super` + `j` / `k` | move focus through windows |
| `Super` + `space` | make focused window the master |
| `Super` + `Shift` + `space` | toggle floating |
| `Super` + `b` | hide/show the bar |

`Super`+`F1` is the one to remember — it opens the complete guide as a PDF.

---

## 5. Finish the setup

Two things the installer cannot do before you have logged in once.

### Browser hardening

The installer tries to generate a LibreWolf profile headlessly, which is
unreliable on a machine with no X session yet. If it reported a failure, open
LibreWolf once, close it, then:

```sh
arkenfox
```

That script is in your dotfiles. It applies the arkenfox `user.js` plus the
LARBS overrides. Extensions are unaffected either way — they come from
`/etc/librewolf/policies/policies.json` and need no profile.

### Wifi

```sh
nmtui
```

Text UI for NetworkManager. Connections persist across reboots.

---

## 6. Verify it worked

```sh
ls -l ~/.zprofile                       # must be a SYMLINK -> .config/shell/profile
echo $DBUS_SESSION_BUS_ADDRESS          # contains /run/user/1000/bus
pgrep -c wireplumber                    # exactly 1
fc-list | grep -ci "noto color emoji"   # at least 1
command -v dwm st dmenu lf xcape        # all found
```

Then in the session: press `Super`+`Return` for a terminal, and check that the
bar along the top shows **icons as well as numbers**.

---

## 7. Troubleshooting

### The bar shows bare numbers with no icons

The emoji font did not install. Every module still prints its value but the
icon is dropped, so it looks like broken scripts when it is a missing font.

```sh
sudo dnf install -y google-noto-color-emoji-fonts fontawesome-fonts-all
fc-cache -f
pkill -HUP dwm
```

### Grey screen, no keybindings work

dwm is not running. X came up but the window manager died or was never built:

```sh
# Ctrl+Alt+F2 for a text console, log in, then:
pgrep -a Xorg; pgrep -a dwm
command -v dwm
grep -i FAILED /var/log/fedora-larbs.log
```

If `dwm` is not found, its build failed — the log says why. Rebuild by hand:

```sh
cd ~/.local/src/dwm && sudo make install && sudo restorecon -RF /usr/local/bin
```

### Password prompts silently fail

Fedora ships a vanilla `dmenu` that lacks the `-P` flag `dmenupass` needs as the
`SUDO_ASKPASS` handler. If Fedora's package ever gets installed it shadows
nothing, but check you have the fork:

```sh
which dmenu          # must be /usr/local/bin/dmenu
rpm -q dmenu         # should say "not installed"
```

### No sound

```sh
systemctl --user status wireplumber
pgrep -c wireplumber   # must be exactly 1; more than one means a conflict
wpctl status
```

### Screen brightness keys do nothing

Your user needs the `video` group (the installer adds it; verify with `groups`).
Log out and back in after any group change.

### Notifications flaky, keyring prompts never appear

A second D-Bus session bus. `echo $DBUS_SESSION_BUS_ADDRESS` must point inside
`$XDG_RUNTIME_DIR`. Make sure nothing reintroduced `dbus-launch` into
`.config/x11/xinitrc`.

### Getting a shell when the session is broken

`Ctrl`+`Alt`+`F2` always gives you a text console. From there, enabling SSH gives
you a proper terminal from another machine:

```sh
sudo dnf install -y openssh-server && sudo systemctl enable --now sshd
ip -brief a
```

### Where the logs are

| | |
|---|---|
| Installer | `/var/log/fedora-larbs.log` |
| X server | `~/.local/share/xorg/Xorg.0.log` — in your home, not `/var/log` |
| SELinux denials | `sudo ausearch -m AVC -ts recent` |

---

## 8. Living with it

### Changing the status bar

Modules are plain scripts in `~/.local/bin/statusbar/`. Run one directly to see
what it prints. Which modules appear, and in what order, is compiled into
dwmblocks:

```sh
cd ~/.local/src/dwmblocks
$EDITOR config.h
sudo make install && sudo restorecon -RF /usr/local/bin
pkill dwmblocks       # it restarts itself
```

The `restorecon` is not optional — SELinux is enforcing and a mislabelled
binary in `/usr/local/bin` will misbehave in confusing ways.

Same pattern for `~/.local/src/dwm`, `st` and `dmenu`.

### Updating dotfiles later

**Do not re-run `fedora.sh` to pick up dotfile changes.** `putgitrepo` copies
over your home unconditionally and will overwrite local edits. Pull the
individual files you want:

```sh
curl -sfL https://raw.githubusercontent.com/Net-Nezvanova/fedorice/fedora/.local/bin/<script> \
  -o ~/.local/bin/<script> && chmod +x ~/.local/bin/<script>
```

Or clone the repo elsewhere and copy across selectively.

### Adding programs

Append a row to `progs.csv`. The tag column is documented at the top of that
file. Anything that lives only in RPM Fusion needs the `F` tag so a missing repo
gives you a clear error rather than `No match for argument`.

### Notes on other environments

- **Proxmox / QEMU VM** — works fully. Create with `--vga virtio` so the guest
  gets a real GPU, and dwm renders directly in the Proxmox console.
- **LXC container** — *cannot work.* Containers share the host kernel and have
  no GPU or DRM device, so Xorg has nothing to drive. You would need Xvfb plus
  x11vnc and a VNC client, and audio, backlight, sensors and disk mounting stay
  dead regardless. Use a VM.
- **Browser-based VNC consoles** (Proxmox noVNC and similar) usually swallow the
  Super key before it reaches the guest. Use Caps Lock as the modifier instead —
  it is mapped to Super and passes through cleanly.
