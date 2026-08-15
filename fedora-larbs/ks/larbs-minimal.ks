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
# USAGE
#
#   Boot the Fedora Everything netinstall ISO and add, at the boot prompt:
#     inst.ks=hd:LABEL=Ventoy:/ks/larbs-minimal.ks
#   or serve it over HTTP:
#     inst.ks=https://example.com/larbs-minimal.ks
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

%packages
@^custom-environment
# The whole point of this file:
@hardware-support           # iwlwifi-*-firmware, intel-gpu-firmware, alsa-sof-firmware, microcode
@networkmanager-submodules  # NetworkManager-wifi, wpa_supplicant
# So fedora.sh can be fetched at all. @core has curl but not git.
git
%end

# Report whether the bootstrap actually worked, while the installer still has a
# log you can read. Checking this here is much cheaper than discovering it after
# a reboot on a machine with no way to get online.
%post --log=/root/larbs-bootstrap.log
echo "=== FedoraLARBS bootstrap check ==="
for p in iwlwifi-mvm-firmware NetworkManager-wifi wpa_supplicant git; do
    if rpm -q --quiet "$p"; then
        echo "ok      $p"
    else
        echo "MISSING $p   <-- first boot will have no network"
    fi
done
echo
echo "Next: reboot, log in as root, confirm 'nmcli device status' shows a"
echo "connected device, then:"
echo "  git clone https://github.com/Net-Nezvanova/FedoraLARBS.git"
echo "  sh FedoraLARBS/fedora-larbs/fedora.sh -n   # dry run first"
echo "  sh FedoraLARBS/fedora-larbs/fedora.sh"
%end

reboot
