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

### Read this before you start: the wifi trap

This is the one failure that can strand you with an unusable machine.

**A Fedora minimal install does not include `NetworkManager-wifi`.** It is a
separate subpackage. You can install Fedora *over wifi*, reboot, and find you
have no wireless at all — a known bug of long standing
([#1195792](https://bugzilla.redhat.com/show_bug.cgi?id=1195792),
[#1230223](https://bugzilla.redhat.com/show_bug.cgi?id=1230223)). And because
`fedora.sh` needs the network to run, no network means you cannot even start.

Precisely, "Minimal Install" is the comps environment `custom-environment`,
which is `@core` and nothing else. `@core` has `NetworkManager` but **not**
`NetworkManager-wifi`, **not** `wpa_supplicant`, and no firmware package of any
kind. Confirm it yourself on any Fedora machine with `dnf group info core`.

`progs.csv` installs all of them, so wifi works *after* the installer runs. The
gap is the window between first boot and that point — and on a wifi-only laptop
that gap is unbridgeable, because `fedora.sh` needs the network in order to
install the things that provide the network. This is why a build that works
perfectly in a VM (virtio NIC, no firmware required) fails on real hardware.

**The fix is to close the gap during installation**, using the kickstart in
`ks/larbs-minimal.ks`:

```
inst.ks=hd:LABEL=Ventoy:/ks/larbs-minimal.ks
```

It is a normal Minimal install plus two comps groups — `@hardware-support`
(the Intel wifi firmware, GPU firmware, SOF audio firmware and microcode) and
`@networkmanager-submodules` (`NetworkManager-wifi`, `wpa_supplicant`). Both are
marked `uservisible: no` in comps, which means **they cannot be ticked in the
Anaconda GUI** — a kickstart is the only practical way to get them into a
Minimal install. Read the header of that file before using it; it leaves
partitioning and the root password interactive on purpose.

If you would rather not use a kickstart, cover the gap with **at least one** of
these instead:

1. **Use an ethernet cable** for the install and the first boot. Simplest and
   completely sidesteps the problem. A cheap USB-ethernet adapter counts.
   Note that some thin laptops — the ThinkPad T480s among them — have no
   full-size RJ45 at all and need a proprietary dongle, so check before relying
   on this.
2. **USB-tether your phone.** Android USB tethering appears as a plain USB
   ethernet device, works with in-kernel drivers, needs no firmware or extra
   packages, and NetworkManager picks it up automatically. This works in the
   Anaconda installer *and* on first boot. This is the reliable escape hatch.
3. **Put the RPMs on the USB stick now, while this machine still works.** Belt
   and braces, and it costs nothing:

   ```sh
   dnf download --resolve --destdir=/mnt/usb/rpms \
     NetworkManager-wifi wpa_supplicant \
     iwlwifi-mvm-firmware iwlwifi-dvm-firmware iwlegacy-firmware
   ```

   Then after first boot: `sudo dnf install /path/to/rpms/*.rpm`

   The firmware packages matter as much as `NetworkManager-wifi`. Fedora's
   `linux-firmware` covers Atheros, Broadcom, Realtek and MediaTek wifi but
   **not Intel**, which is what is in most laptops — and nothing in the
   dependency graph pulls the Intel firmware in.

Do not rely on wifi alone.

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

If you are using `ks/larbs-minimal.ks` (recommended — see the wifi trap above),
add `inst.ks=hd:LABEL=Ventoy:/ks/larbs-minimal.ks` at the boot prompt, adjusting
the label and path to wherever you put the file. The kickstart sets the software
selection for you; Anaconda will still stop and ask for the disk layout and the
root password. Step 3 below is then handled for you — do the rest as written.

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

**Check the network before anything else.** This is the single check that
catches the wifi trap, and it takes five seconds:

```sh
nmcli device status                       # a device must say "connected"
rpm -q NetworkManager-wifi wpa_supplicant iwlwifi-mvm-firmware
```

If the device list has no connected entry, or any of those packages reports
"not installed", stop here and fix the network first — see the wifi trap in
section 0. Running `fedora.sh` without a working network fails immediately at
its host check, and on a laptop with no other OS that is how people end up
stranded. Everything below assumes this check passed.

```sh
dnf install -y git
git clone https://github.com/Net-Nezvanova/FedoraLARBS.git
cd FedoraLARBS/fedora-larbs
```

**Dry run first.** It installs nothing, needs no root, and takes about half a
minute. It resolves every package name against your actual Fedora release,
which is what turns a 40-minute failure into a 30-second one:

```sh
./fedora.sh -n
```

Every line should say `ok`. Warnings about optional ueberzugpp build
dependencies are fine — image previews fall back to chafa. Anything reported as
`MISS` needs fixing in `progs.csv` before continuing.

**Then install:**

```sh
./fedora.sh
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

### Claude Code (optional, but useful for fixing this system)

Anthropic publishes a signed dnf repository, so this stays Fedora-native and
needs no Node.js:

```sh
sudo tee /etc/yum.repos.d/claude-code.repo <<'EOF'
[claude-code]
name=Claude Code
baseurl=https://downloads.claude.ai/claude-code/rpm/stable
enabled=1
gpgcheck=1
gpgkey=https://downloads.claude.ai/keys/claude-code.asc
EOF

sudo dnf install claude-code
```

dnf prompts you to confirm the signing key on first install. Verify the
fingerprint reads `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE` before
accepting it.

Then run `claude` and follow the browser login. Requires a Pro, Max, Team or
Enterprise account; the free plan does not include Claude Code. Upgrade later
with `sudo dnf upgrade claude-code` — package installs do not self-update.

This is deliberately not in `progs.csv`: authentication is interactive, so it
cannot be automated during the install anyway.

---

## 6. Verify it worked

```sh
ls -l ~/.zprofile                       # must be a SYMLINK -> .config/shell/profile
echo $DBUS_SESSION_BUS_ADDRESS          # contains /run/user/1000/bus
pgrep -c wireplumber                    # exactly 1
fc-list | grep -ci NotoEmoji-           # at least 1 - the B&W font the bar needs
command -v dwm st dmenu lf xcape        # all found
```

Then in the session: press `Super`+`Return` for a terminal, and check that the
bar along the top shows **icons as well as numbers**.

---

## 7. Troubleshooting

### The bar shows bare numbers with no icons

You are missing the **black-and-white** emoji font. This one is subtle and worth
understanding, because installing the obvious package does not fix it.

dwm's `drw.c`, in the code path that looks for a fallback font when a glyph is
missing from the primary font, contains:

```c
FcPatternAddBool(fcpattern, FC_COLOR, FcFalse);
```

That tells fontconfig *not to return a colour font*. Every status bar icon is an
emoji, and `google-noto-color-emoji-fonts` is a colour font, so dwm rejects it
and draws nothing — while the numbers, which live in the monospace font, render
normally. The result looks like broken scripts and is actually a font policy.

The fix is the monochrome font:

```sh
sudo dnf install -y google-noto-emoji-fonts
fc-cache -f
pkill -HUP dwm
```

`progs.csv` installs it, so a fresh install should not hit this.

To confirm the diagnosis first, print an emoji **inside st**:

```sh
printf '🧠 🔻 🔊 📦\n'
```

If they appear in the terminal but not in the bar, it is exactly this — st and
dwm have different font-fallback rules. If they appear in neither, then the
fonts really are missing:

```sh
fc-list | grep -iE 'NotoEmoji|NotoColorEmoji|awesome'
sudo dnf install -y google-noto-emoji-fonts google-noto-color-emoji-fonts fontawesome-fonts-all
fc-cache -f && pkill -HUP dwm
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

### No wifi after first boot

The trap described in §0. Get a network by cable or phone tethering, then:

```sh
sudo dnf install -y NetworkManager-wifi
sudo systemctl restart NetworkManager
nmtui
```

If `ip link` shows no wireless device **at all** — only `lo` and `enp*` — it is
missing firmware, not configuration. Do **not** reach for `linux-firmware`: it is
already installed (the kernel recommends it) and dnf will tell you there is
nothing to do, which reads like the card is unsupported when it is not.

Fedora's `linux-firmware` covers Atheros, Broadcom, Realtek and MediaTek wifi
but deliberately **not** Intel. Those are separate packages that nothing pulls
in automatically:

```sh
sudo dnf install -y iwlwifi-mvm-firmware iwlwifi-dvm-firmware iwlegacy-firmware
sudo reboot
```

Confirm with `dmesg | grep -i iwlwifi` — `Direct firmware load for
iwlwifi-*.ucode failed with error -2` is the signature of exactly this.

`progs.csv` installs all three, so a completed run should never leave you here.

### No sound

```sh
systemctl --user status wireplumber
pgrep -c wireplumber   # must be exactly 1; more than one means a conflict
wpctl status
```

If `wpctl status` shows no sink at all on a laptop made since roughly 2019, the
audio firmware is missing:

```sh
sudo dnf install -y alsa-sof-firmware && sudo reboot
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
