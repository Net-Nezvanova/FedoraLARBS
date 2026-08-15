# larbs-minimal.ks -- base install for FedoraLARBS on bare metal.
#
# WHAT THIS IS FOR
#
# Fedora's "Minimal Install" is the comps environment `custom-environment`,
# which is `@core` and nothing else. @core contains NetworkManager but NOT
# NetworkManager-wifi, NOT wpa_supplicant, and no firmware package of any kind.
# `linux-firmware` does not depend on the Intel wifi firmware either -- that
# lives in the standalone `iwlwifi-mvm-firmware` package, which is only reachable
# through the `@hardware-support` group.
#
# The result on a wifi-only laptop is a freshly installed system with no network
# at all. fedora.sh cannot fix that, because fedora.sh needs the network in order
# to install the packages that would provide it. progs.csv lists every one of
# them correctly and it makes no difference: they are on the wrong side of the
# boundary. In a VM the same install works, because a virtio/e1000 NIC needs no
# firmware and @core's NetworkManager drives it.
#
# Anaconda's installer environment already has all firmware loaded, so it can
# install these into the target system. That is the only place this can be
# broken, and it is what this file does.
#
# The two groups below are `uservisible: no` in comps, which means they cannot
# be ticked in the Anaconda GUI. A kickstart is the only practical way to get
# them into a Minimal install.
#
#
# WHY THIS FILE DOES NOT TRUST ITS OWN %packages SECTION
#
# Because on 2026-08-15 that was not enough, on a ThinkPad T480s, using a
# near-identical copy of this file.
#
# The kickstart reached Anaconda intact -- verified afterwards by diffing
# /root/original-ks.cfg against the deployed file, byte for byte identical -- and
# it parses cleanly, confirmed by re-running it through pykickstart's F44 handler
# and ksvalidator:
#
#     environment : custom-environment
#     groups      : ['hardware-support', 'networkmanager-submodules']
#     packages    : ['git']
#
# Anaconda nonetheless committed only this, per /root/anaconda-ks.cfg:
#
#     %packages
#     @^custom-environment
#     @networkmanager-submodules
#     %end
#
# @hardware-support and git were dropped silently. No error, no prompt, no log
# entry; the install reported success. Everything else in the kickstart applied
# normally -- keyboard, selinux, firewall, services, %post. Only the package
# additions were discarded. @networkmanager-submodules survived because Anaconda
# adds that group itself when a wifi connection is configured in the Network
# spoke, not because the kickstart asked for it.
#
# The likeliest trigger is visiting the Software Selection spoke, which
# re-derives the package set from what the GUI can see and discards
# kickstart-only additions -- and these groups are invisible to it by
# definition. That was not proven, so this file does not depend on the answer.
#
# The %post block below therefore verifies what actually landed and installs
# whatever is missing itself. It runs after the payload, inside the chroot, while
# the netinstall's network is still up, which puts it downstream of anything the
# GUI did to the package selection.
#
#
# THE RULE THAT COST AN EVENING
#
# iwlwifi -- and every other wifi driver -- reads its firmware once, when the
# driver probes at boot. Installing firmware into a running system that has
# already failed to find it changes nothing until the driver probes again. On
# 2026-08-15 the missing firmware was installed correctly over an ethernet
# dongle and the machine was powered off without rebooting, so a working fix
# presented as a failed one. REBOOT AFTER INSTALLING WIFI FIRMWARE.
#
#
# USAGE
#
#   Boot the Fedora Everything netinstall ISO and add, at the boot prompt:
#     inst.ks=hd:LABEL=Ventoy:/ks/larbs-minimal.ks
#   or serve it over HTTP:
#     inst.ks=https://example.com/larbs-minimal.ks
#
#   BEFORE YOU REBOOT OUT OF THE INSTALLER, read /root/larbs-bootstrap.log in
#   the target. It states in plain words whether first boot will have network.
#   It is the cheapest check in the whole process, and on 2026-08-15 it called
#   the failure correctly and went unread.
#
# DELIBERATELY LEFT INTERACTIVE
#
# Disk partitioning and the root password are NOT set here. This file lives in a
# public repository, and a kickstart that silently repartitions is one typo away
# from destroying whatever else is on the machine. Anaconda will stop and ask for
# both. Automate them only in a local copy -- see the commented blocks below.
#
# In the installer:
#   - Set a ROOT PASSWORD. You need it to run fedora.sh on first boot.
#   - SKIP user creation entirely. fedora.sh creates the user, sets the shell to
#     zsh, and adds it to wheel and video.

text
keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
timezone Etc/UTC --utc
selinux --enforcing
firewall --enabled
services --enabled=NetworkManager

# NETWORK
#
# Configuring wifi interactively in the installer is enough: Anaconda copies the
# connection profile it used into the installed system, so it comes back after
# reboot. Verify it on first boot with `nmcli device status` before doing
# anything else.
#
# To bake the credentials in instead, uncomment the line below. The PSK is stored
# in cleartext, both in this file and in the installer logs under /var/log, so do
# not commit a real one. `wlp61s0` is this ThinkPad T480s's interface name; check
# yours with `ip link` from the live environment.
#
#network --device=wlp61s0 --essid=YOUR_SSID --wpakey=YOUR_PSK --bootproto=dhcp --onboot=yes --activate
#network --hostname=changeme

# PARTITIONING -- uncomment exactly one block in a local copy.
#
# Wipe the entire disk. This destroys everything on it, Windows included.
#ignoredisk --only-use=nvme0n1
#clearpart --all --initlabel --drives=nvme0n1
#autopart --type=btrfs --noswap
#bootloader --boot-drive=nvme0n1
#
# Dual-boot alongside an existing Windows install. Shrink the Windows NTFS
# partition from inside Windows Disk Management FIRST -- do not let a Linux tool
# resize a filesystem Windows may have left dirty or hibernated. Note that a
# Windows-created ESP is typically only 100-260 MB, which is tight once Fedora
# keeps three kernels in it; expect to prune old kernels or accept a full /boot.
#ignoredisk --only-use=nvme0n1
#reqpart
#part / --fstype=btrfs --size=61440 --grow
#bootloader --boot-drive=nvme0n1

# The fast path. Believed but NOT trusted -- %post verifies and repairs.
%packages
@^custom-environment
@hardware-support
@networkmanager-submodules
git
%end

# Verify what actually landed, install whatever did not, and refuse to be quiet
# if that fails. Runs in the chroot with the netinstall's network still up.
%post --log=/root/larbs-bootstrap.log
echo "=== FedoraLARBS bootstrap check -- $(date -u '+%Y-%m-%d %H:%M UTC') ==="
echo

# Needed on every machine: the wifi stack, and git so fedora.sh can be fetched
# at all (@core has curl but not git).
pkgs="NetworkManager-wifi wpa_supplicant git"
grps=""

# Firmware is hardware-specific, so ask the hardware. The installer environment
# has every firmware package loaded, which means the driver it has already bound
# to the wireless card is authoritative -- read it out of sysfs and name that
# vendor's package directly. Anything unrecognised falls back to the whole
# @hardware-support group rather than guessing.
saw_net=0
saw_wifi=0
for n in /sys/class/net/*; do
    [ -e "$n" ] || continue
    saw_net=1
    [ -d "$n/phy80211" ] || continue
    saw_wifi=1
    drv=$(readlink -f "$n/device/driver" 2>/dev/null)
    drv=${drv##*/}
    echo "wireless device: ${n##*/}   driver: ${drv:-unknown}"
    case "$drv" in
        iwlwifi)          pkgs="$pkgs iwlwifi-mvm-firmware iwlwifi-dvm-firmware" ;;
        iwlegacy|iwl4965|iwl3945)
                          pkgs="$pkgs iwlegacy-firmware" ;;
        ath6kl*|ath9k*|ath10k*|ath11k*|ath12k*)
                          pkgs="$pkgs atheros-firmware" ;;
        brcmfmac|brcmsmac)
                          pkgs="$pkgs brcmfmac-firmware" ;;
        b43*)             pkgs="$pkgs b43-openfwwf" ;;
        mt76*|mt79*)      pkgs="$pkgs mt7xxx-firmware" ;;
        rtw88*|rtw89*|rtl*)
                          pkgs="$pkgs realtek-firmware" ;;
        mwifiex*)         pkgs="$pkgs nxpwireless-firmware" ;;
        libertas*)        pkgs="$pkgs libertas-firmware" ;;
        wl12xx|wl18xx|wlcore*)
                          pkgs="$pkgs tiwilink-firmware" ;;
        "")               echo "  (no driver bound; falling back to the full group)"
                          grps="@hardware-support" ;;
        *)                echo "  (driver not in this file's map; falling back to the full group)"
                          grps="@hardware-support" ;;
    esac
done

if [ "$saw_net" = 0 ]; then
    # sysfs not visible here for some reason. Do not silently skip firmware --
    # that is precisely the bug this block exists to prevent.
    echo "note: /sys/class/net is unreadable, cannot detect hardware."
    echo "      installing the whole @hardware-support group instead."
    grps="@hardware-support"
elif [ "$saw_wifi" = 0 ]; then
    echo "note: no wireless device present. Skipping wifi firmware."
fi
echo

missing=""
for p in $pkgs; do
    if rpm -q --quiet "$p"; then
        echo "ok       $p"
    else
        echo "missing  $p"
        missing="$missing $p"
    fi
done
echo

if [ -n "$missing" ] || [ -n "$grps" ]; then
    echo "--- installing:$missing $grps"
    echo "--- (%packages did not deliver these, or the group needs re-asserting)"
    dnf -y install $missing $grps 2>&1 || echo "--- dnf returned $?"
    echo
fi

# Re-check. This is the answer that matters; everything above is narration.
failed=""
for p in $pkgs; do
    rpm -q --quiet "$p" || failed="$failed $p"
done

if [ -z "$failed" ]; then
    echo "RESULT: ok -- everything required is present. First boot should have network."
    [ -n "$grps" ] && echo "NOTE: hardware could not be identified precisely; @hardware-support was"
    [ -n "$grps" ] && echo "      installed wholesale. Confirm with 'nmcli device status' on first boot."
    echo
    echo "On first boot, log in as root and confirm:"
    echo "  nmcli device status          # want a device in state 'connected'"
    echo
    echo "Then:"
    echo "  git clone https://github.com/Net-Nezvanova/FedoraLARBS.git"
    echo "  sh FedoraLARBS/fedora-larbs/fedora.sh -n   # dry run, ~30s"
    echo "  sh FedoraLARBS/fedora-larbs/fedora.sh"
else
    echo "RESULT: FAILED -- still missing:$failed"
    echo
    echo "First boot will have NO NETWORK on a wifi-only machine. The install is"
    echo "fine and nothing is lost, but you need a wire or a live USB to finish."

    # Make this impossible to walk past. Whoever logs in next sees it before
    # they get a chance to type anything.
    cat > /root/NETWORK-BROKEN-README <<EOF
This install finished, but these packages are missing:$failed

If a wifi firmware package is in that list, this machine has no wifi: the driver
loads, finds the card, and has no firmware to give it. Confirm with

    dmesg | grep -iE 'firmware|iwlwifi|ath|brcm'

where you are looking for a line like "no suitable firmware found!".

To fix it you need a network from somewhere else. Either:

  a) Plug in ethernet, or USB-tether an Android phone (it appears as a plain
     USB ethernet device and needs no firmware), then:
       dnf install -y$failed
       reboot                # REQUIRED -- see below

  b) Or boot a Fedora live USB, which has all firmware, and install into this
     system from there. Mount the target first -- adjust the device, and if you
     encrypted the disk, 'cryptsetup open' it before mounting:
       sudo mount -o subvol=root /dev/nvme0n1p3 /mnt
       sudo mount /dev/nvme0n1p2 /mnt/boot
       sudo dnf --installroot=/mnt --releasever=\$(rpm -E %fedora) -y install$failed
       sudo umount -R /mnt
     Then reboot into this system.

THE REBOOT IS NOT OPTIONAL. Wifi drivers read their firmware once, when the
driver probes at boot. Installing firmware into a running system that already
failed to find it does nothing until the driver probes again. This exact detail
made a correct fix look like a failed one on 2026-08-15.

Delete this file once the network works.
EOF

    cat > /etc/motd <<EOF

  *** NO NETWORK ON THIS SYSTEM -- read /root/NETWORK-BROKEN-README ***

  Missing:$failed

EOF
fi
%end

reboot
