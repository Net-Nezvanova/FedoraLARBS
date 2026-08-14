#!/bin/sh

# Fedora LARBS -- Luke Smith's Auto-Rice Bootstrapping Script, ported to Fedora.
# Upstream: Luke Smith <luke@lukesmith.xyz>, https://larbs.xyz -- License: GPLv3
#
# Run as root on a fresh minimal Fedora install. Creates a user, installs the
# programs in progs.csv, deploys the dotfiles, and configures the system so
# that logging in on tty1 drops you straight into dwm.
#
# Differences from upstream larbs.sh that matter, all deliberate:
#   * dnf/rpm replace pacman; there is no AUR, so source builds and pipx cover
#     what Fedora does not package.
#   * /bin/sh is NOT relinked to dash. bash owns /usr/bin/sh on Fedora and RPM
#     scriptlets are permitted to contain bashisms.
#   * wheel is a supplementary group, not the primary one (user private groups).
#   * All output goes to a log file instead of /dev/null, so failures are
#     diagnosable.

### CONFIGURATION ###

# The dotfiles this installer deploys. Override with -r to use a different fork.
# It must be a FEDORA fork -- upstream voidrice is Arch-specific and deploying it
# would produce a broken system.
dotfilesrepo="https://github.com/Net-Nezvanova/fedorice.git"
# Subdirectory within that repo holding the dotfiles themselves (the directory
# that contains .config and .local). Leave empty if they sit at the repo root;
# set it with -d if you keep the installer and the dotfiles in one repository.
dotfilesdir=""
# Resolved so the script can be invoked from anywhere and still find the files
# that ship beside it (progs.csv, vendor/).
scriptdir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
progsfile="$scriptdir/progs.csv"
repobranch="fedora"
logfile="/var/log/fedora-larbs.log"

ueberzugpprepo="https://github.com/jstkdng/ueberzugpp.git"
ueberzugpptag="v2.9.6"
lfrepo="https://github.com/gokcehan/lf.git"
arkenfoxurl="https://raw.githubusercontent.com/arkenfox/user.js/master/user.js"

# Needed before progs.csv can be processed at all. Kept here rather than in the
# CSV because the CSV is data and this is the bootstrap that reads it.
bootstrappkgs="ca-certificates curl git zsh policycoreutils util-linux chrony
gcc gcc-c++ make cmake pkgconf-pkg-config patch golang pipx psmisc procps-ng
libX11-devel libXft-devel libXinerama-devel libXext-devel libXtst-devel
freetype-devel fontconfig-devel harfbuzz-devel"

# Fedora has no base-devel equivalent that includes the X headers, so they are
# enumerated above. Without them dwm/st/dmenu fail on <X11/Xlib.h>.

# Fedora names two of these differently from most distributions: the libvips
# devel package is vips-devel, and nlohmann/json ships as json-devel.
ueberzugppdeps="cmake gcc-c++ openssl-devel vips-devel spdlog-devel
fmt-devel json-devel tbb-devel libxcb-devel xcb-util-image-devel
chafa-devel cli11-devel"

dryrun=0
export TERM=ansi

# git must never stop to ask for credentials. This runs unattended behind a
# whiptail UI, where a prompt is invisible and simply hangs the install forever
# with no indication of why. With this set, a private or misnamed repository
# fails immediately and says so.
export GIT_TERMINAL_PROMPT=0

### ARGUMENTS ###

usage() {
	cat <<-USAGE
	Usage: fedora.sh -r <dotfiles-repo> [-d subdir] [-b branch] [-p progs.csv] [-n] [-h]

	  -r  git URL of a Fedora fork of voidrice to deploy
	      (default: $dotfilesrepo)
	  -d  subdirectory of that repo containing the dotfiles, if they are not at
	      its root. Use this when the installer and the dotfiles share one
	      repository, e.g. -d voidrice
	  -b  branch of that repo to deploy (default: $repobranch)
	  -p  path or URL of the programs list (default: $progsfile)
	  -n  dry run: resolve every package and repo without installing anything
	  -h  show this message

	Run as root on a fresh minimal Fedora install. Do the dry run first.
	USAGE
	exit "${1:-0}"
}

while getopts ":r:d:b:p:nh" o; do
	case "$o" in
	h) usage ;;
	r) dotfilesrepo="$OPTARG" ;;
	d) dotfilesdir="${OPTARG#/}" && dotfilesdir="${dotfilesdir%/}" ;;
	b) repobranch="$OPTARG" ;;
	p) progsfile="$OPTARG" ;;
	n) dryrun=1 ;;
	*)
		# Must not exit 0: a typo in a flag would otherwise be reported to any
		# calling script as a successful run.
		printf "Invalid option: -%s\\n\\n" "$OPTARG" >&2
		usage 1
		;;
	esac
done

### HELPERS ###

error() {
	printf "\033[31mERROR:\033[0m %s\\n" "$1" >&2
	if [ -s "$logfile" ]; then
		printf "\\nLast 15 lines of %s:\\n" "$logfile" >&2
		tail -n 15 "$logfile" >&2
	fi
	exit 1
}

logmsg() {
	printf "\\n=== %s ===\\n" "$1" >>"$logfile" 2>/dev/null
}

# Records a non-fatal failure so finalize() can report it instead of the user
# discovering it weeks later.
notework() {
	printf "%s\\n" "$1" >>"$failedlist"
	printf "FAILED: %s\\n" "$1" >>"$logfile"
}

checkhost() {
	if [ "$dryrun" -eq 0 ]; then
		[ "$(id -u)" -eq 0 ] ||
			error "This script must be run as root. A dry run (-n) does not need root."
	fi

	[ -f /etc/fedora-release ] ||
		error "/etc/fedora-release is missing. This script is for Fedora only."
	command -v dnf >/dev/null 2>&1 || error "dnf was not found on this system."
	fedver="$(rpm -E %fedora)"

	# A CRLF copy of this script would die on its own shebang, and every script
	# in the dotfiles repo would die the same way. Catch it here rather than
	# after the user has answered four prompts.
	if ! tr -d '\r' <"$0" | cmp -s - "$0"; then
		error "This script has CRLF line endings and cannot run. It was probably copied from Windows instead of cloned with git. Fix with: sed -i 's/\r\$//' $0 -- and check the dotfiles repo the same way."
	fi

	curl -sfI https://mirrors.fedoraproject.org >/dev/null 2>&1 ||
		error "No network connection (could not reach mirrors.fedoraproject.org)."

	[ -n "$dotfilesrepo" ] ||
		error "No dotfiles repository given. Pass -r with the git URL of your Fedora fork of voidrice. Upstream voidrice is Arch-specific and will not work."
}

### DRY RUN ###

# Resolves everything the real run would install, without touching the system.
# This is what catches a wrong package name in 30 seconds instead of 40 minutes.
resolve() {
	tmpprogs="$(mktemp)"
	readprogs "$tmpprogs"
	missing=0
	warned=0

	# On a bare @core system git is not installed yet, so a failed ls-remote
	# would be reported as a missing repository. Say so instead of lying.
	havegit=0
	command -v git >/dev/null 2>&1 && havegit=1

	printf "Resolving against Fedora %s\\n\\n" "$fedver"
	[ "$havegit" -eq 0 ] &&
		printf "note: git is not installed yet, so source repositories are not checked.\\n\\n"

	printf "Bootstrap packages:\\n"
	for p in $bootstrappkgs; do
		checkpkg "$p" || missing=$((missing + 1))
	done

	printf "\\nprogs.csv (%s rows):\\n" "$(wc -l <"$tmpprogs")"
	while IFS=, read -r tag program comment <&3; do
		case "$tag" in
		G)
			if [ "$havegit" -eq 0 ]; then
				printf "  skip  git     %s\\n" "$program"
			elif git ls-remote --exit-code "$program" >/dev/null 2>&1; then
				printf "  ok    git     %s\\n" "$program"
			else
				printf "  MISS  git     %s\\n" "$program"
				missing=$((missing + 1))
			fi
			;;
		R)
			if [ "$program" = xcape ] && [ ! -f "$scriptdir/vendor/xcape/xcape.c" ]; then
				printf "  MISS  vendor  %s (expected %s)\\n" "$program" "$scriptdir/vendor/xcape/xcape.c"
				missing=$((missing + 1))
			else
				printf "  --    recipe  %s (build deps checked below)\\n" "$program"
			fi
			;;
		P) printf "  --    pipx    %s\\n" "$program" ;;
		F)
			if rpm -q --quiet rpmfusion-free-release; then
				checkpkg "$program" || missing=$((missing + 1))
			else
				printf "  --    rpmfusion %s (repo not enabled yet)\\n" "$program"
			fi
			;;
		L)
			if [ -f /etc/yum.repos.d/librewolf.repo ]; then
				checkpkg "$program" || missing=$((missing + 1))
			else
				printf "  --    librewolf %s (repo not enabled yet)\\n" "$program"
			fi
			;;
		*) checkpkg "$program" || missing=$((missing + 1)) ;;
		esac
	done 3<"$tmpprogs"

	# Warnings, not errors. The ueberzugpp build is deliberately non-fatal, so a
	# missing build dependency costs image previews -- lf falls back to chafa --
	# rather than costing the installation. Blocking on these would be wrong.
	printf "\\nueberzugpp build dependencies (optional; previews fall back to chafa):\\n"
	for p in $ueberzugppdeps; do
		checkpkg "$p" || warned=$((warned + 1))
	done

	printf "\\nSource repositories:\\n"
	for u in "$lfrepo" "$ueberzugpprepo" "$dotfilesrepo"; do
		[ -n "$u" ] || continue
		if [ "$havegit" -eq 0 ]; then
			printf "  skip  git     %s\\n" "$u"
		elif git ls-remote --exit-code "$u" >/dev/null 2>&1; then
			printf "  ok    git     %s\\n" "$u"
		else
			printf "  MISS  git     %s\\n" "$u"
			missing=$((missing + 1))
		fi
	done

	rm -f "$tmpprogs"
	printf "\\n"
	[ "$warned" -gt 0 ] &&
		printf "\033[33m%s optional ueberzugpp build dep(s) unavailable.\033[0m Install continues; image previews will use chafa.\\n" "$warned"
	if [ "$missing" -gt 0 ]; then
		printf "\033[31m%s item(s) could not be resolved.\033[0m Fix progs.csv before installing.\\n" "$missing"
		exit 1
	fi
	printf "\033[32mEverything required resolved.\033[0m\\n"
	exit 0
}

checkpkg() {
	if [ -n "$(dnf -q repoquery --qf '%{name}' "$1" 2>/dev/null)" ]; then
		printf "  ok    dnf     %s\\n" "$1"
		return 0
	fi
	printf "  MISS  dnf     %s\\n" "$1"
	return 1
}

### USER INTERACTION ###

welcomemsg() {
	whiptail --title "Fedora LARBS" \
		--msgbox "Welcome to the Fedora port of Luke Smith's Auto-Rice Bootstrapping Script.\\n\\nThis will install a fully-featured dwm desktop on this Fedora system." 10 60

	whiptail --title "Important" --yes-button "Continue" --no-button "Cancel" \
		--yesno "This is a fresh-install script. It creates a user, enables RPM Fusion and the LibreWolf repository, builds several programs from source, and rewrites parts of /etc.\\n\\nIf you have already configured this machine, read RUNBOOK.md first -- re-running this script overwrites dotfiles." 13 70
}

getuserandpass() {
	name=$(whiptail --inputbox "First, please enter a name for the user account." 10 60 3>&1 1>&2 2>&3 3>&1) || return 1
	while ! echo "$name" | grep -q "^[a-z_][a-z0-9_-]*$"; do
		name=$(whiptail --nocancel --inputbox "Username not valid. Give a username beginning with a letter, with only lowercase letters, - or _." 10 60 3>&1 1>&2 2>&3 3>&1)
	done
	pass1=$(whiptail --nocancel --passwordbox "Enter a password for that user." 10 60 3>&1 1>&2 2>&3 3>&1)
	pass2=$(whiptail --nocancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&1)
	while ! [ "$pass1" = "$pass2" ]; do
		unset pass2
		pass1=$(whiptail --nocancel --passwordbox "Passwords do not match.\\n\\nEnter password again." 10 60 3>&1 1>&2 2>&3 3>&1)
		pass2=$(whiptail --nocancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&1)
	done
}

usercheck() {
	! { id -u "$name" >/dev/null 2>&1; } ||
		whiptail --title "Warning" --yes-button "Continue" --no-button "Cancel" \
			--yesno "The user \`$name\` already exists on this system. This script will OVERWRITE any conflicting settings and dotfiles in that user's home, and will change their password to the one you just entered." 14 70
}

preinstallmsg() {
	whiptail --title "Ready" --yes-button "Let's go!" --no-button "Cancel" \
		--yesno "Everything is ready. The rest of the installation is fully automated and will take a while -- the source builds and the browser are the slow parts.\\n\\nOutput is logged to $logfile." 13 70 || {
		clear
		exit 1
	}
}

finalize() {
	# A missing window manager is not a partial success. Telling someone the
	# session will start when dwm was never built sends them to a grey screen
	# with no terminal and no idea why, which is a genuinely bad place to be.
	wmok=1
	for p in dwm st dmenu; do
		command -v "$p" >/dev/null 2>&1 || wmok=0
	done
	if [ "$wmok" -eq 0 ]; then
		whiptail --title "Installed, but the desktop will NOT start" \
			--msgbox "One of dwm, st or dmenu was not built, so logging in will give you a grey screen with no way to open a terminal.\\n\\nPress Ctrl+Alt+F2 for a text console and look for the build error:\\n\\n  grep -i FAILED $logfile\\n\\nThen rebuild by hand, for example:\\n\\n  cd ~/.local/src/dwm && sudo make install\\n  sudo restorecon -RF /usr/local/bin\\n\\nOther failures:\\n$(cat "$failedlist" 2>/dev/null)" 24 74
		return
	fi
	if [ -s "$failedlist" ]; then
		whiptail --title "Installed, with failures" \
			--msgbox "The installation finished, but these items failed:\\n\\n$(cat "$failedlist")\\n\\nSee $logfile for the reason. Everything else is in place: log out, log back in as $name, and the session will start automatically on tty1." 20 70
	else
		whiptail --title "All done" \
			--msgbox "Installation complete.\\n\\nLog out and log back in as $name on tty1; the graphical session starts by itself.\\n\\nNote: re-running this script overwrites dotfiles in that home directory." 14 70
	fi
}

### INSTALL PRIMITIVES ###

installpkg() {
	rpm -q --quiet "$1" && return 0
	dnf -y install "$1" >>"$logfile" 2>&1
}

readprogs() {
	# Upstream only strips comments on the curl path, so a local CSV feeds its
	# own header row to the installer. Strip on both paths.
	if [ -f "$progsfile" ]; then
		sed '/^#/d;/^[[:space:]]*$/d' "$progsfile" >"$1"
	else
		curl -Ls "$progsfile" | sed '/^#/d;/^[[:space:]]*$/d' >"$1"
	fi
	[ -s "$1" ] || error "The programs list ($progsfile) is empty or could not be read."
}

maininstall() {
	whiptail --title "Fedora LARBS Installation" \
		--infobox "Installing \`$1\` ($n of $total). $1 $2" 9 70
	installpkg "$1" || notework "dnf: $1"
}

# Applies the small source patches this port needs before make runs.
patchsource() {
	case "$1" in
	dwm)
		[ -f config.h ] || return 0
		# The laptop brightness keys are bound to xbacklight, which is a no-op on
		# modern KMS drivers and is not packaged for Fedora at all. brightnessctl
		# is what actually works, and progs.csv installs it.
		sed -i 's/"xbacklight", "-inc", "15"/"brightnessctl", "set", "15%+"/;
		        s/"xbacklight", "-dec", "15"/"brightnessctl", "set", "15%-"/' config.h
		;;
	dwmblocks)
		[ -f config.h ] || [ ! -f config.def.h ] || cp config.def.h config.h
		[ -f config.h ] || return 0
		# The status bar references modules this port does not ship: the package
		# module was renamed for dnf, and the mail and RSS modules went with
		# neomutt and newsboat.
		sed -i 's/sb-pacpackages/sb-dnfpackages/g' config.h
		sed -i '/sb-mailbox/d;/sb-news/d' config.h
		;;
	esac
}

gitmakeinstall() {
	progname="${1##*/}"
	progname="${progname%.git}"
	dir="$repodir/$progname"
	whiptail --title "Fedora LARBS Installation" \
		--infobox "Installing \`$progname\` ($n of $total) via git and make. $progname $2" 9 70
	logmsg "git+make $progname"
	sudo -u "$name" -H git -C "$repodir" clone --depth 1 --single-branch \
		--no-tags -q "$1" "$dir" >>"$logfile" 2>&1 ||
		{
			cd "$dir" 2>/dev/null || {
				notework "git clone: $1"
				return 1
			}
			sudo -u "$name" -H git pull --force origin master >>"$logfile" 2>&1
		}
	cd "$dir" || {
		notework "git: $progname"
		return 1
	}
	patchsource "$progname"
	make >>"$logfile" 2>&1 && make install >>"$logfile" 2>&1 || notework "make: $progname"
	cd /tmp || return 1
	relabel
}

recipeinstall() {
	whiptail --title "Fedora LARBS Installation" \
		--infobox "Building \`$1\` from source ($n of $total). $1 $2" 9 70
	logmsg "recipe $1"
	"build_$1" || notework "build recipe: $1"
}

pipxinstall() {
	whiptail --title "Fedora LARBS Installation" \
		--infobox "Installing \`$1\` ($n of $total) with pipx. $1 $2" 9 70
	logmsg "pipx $1"
	sudo -u "$name" -H env HOME="/home/$name" \
		PIPX_HOME="/home/$name/.local/share/pipx" \
		PIPX_BIN_DIR="/home/$name/.local/bin" \
		pipx install --force "$1" >>"$logfile" 2>&1 || notework "pipx: $1"
}

### BUILD RECIPES ###

# lf is a Go program, so `make && make install` does not apply.
build_lf() {
	dir="$repodir/lf"
	rm -rf "$dir"
	sudo -u "$name" -H git -C "$repodir" clone --depth 1 --single-branch \
		--no-tags -q "$lfrepo" "$dir" >>"$logfile" 2>&1 || return 1
	# Under `sudo -u` on Fedora, HOME is still /root -- Fedora's sudoers sets
	# env_reset but not always_set_home. Every one of these must be explicit or
	# the build tries to write root's cache as an unprivileged user and fails.
	# The paths mirror what .config/shell/profile already exports.
	sudo -u "$name" -H env \
		HOME="/home/$name" \
		GOPATH="/home/$name/.local/share/go" \
		GOCACHE="/home/$name/.cache/go/build" \
		GOMODCACHE="/home/$name/.cache/go/mod" \
		CGO_ENABLED=0 \
		sh -c "cd '$dir' && go build -o lf" >>"$logfile" 2>&1 || return 1
	install -Dm755 "$dir/lf" /usr/local/bin/lf || return 1
	[ -f "$dir/lf.1" ] && install -Dm644 "$dir/lf.1" /usr/local/share/man/man1/lf.1
	relabel
}

# xcape is vendored rather than cloned. Upstream github.com/alols/xcape was
# deleted, and the surviving forks are either divergent variants or unvetted, so
# the source in vendor/xcape is Debian's packaged 1.2 (GPL-3.0, Albin Olsson).
# Building from a committed copy means the install depends on no third-party
# repository at all, and the exact source is auditable in this repo.
build_xcape() {
	src="$scriptdir/vendor/xcape"
	[ -f "$src/xcape.c" ] || {
		printf "vendored xcape source missing at %s\\n" "$src" >>"$logfile"
		return 1
	}
	dir="$repodir/xcape"
	rm -rf "$dir"
	mkdir -p "$dir"
	cp -f "$src"/xcape.c "$src"/Makefile "$src"/xcape.1 "$src"/LICENSE "$dir"/ || return 1
	chown -R "$name":"$name" "$dir"
	sudo -u "$name" -H make -C "$dir" >>"$logfile" 2>&1 || return 1
	# Upstream's Makefile defaults to PREFIX=/usr with an odd MANDIR; point both
	# at /usr/local so it lands with the other source-built programs.
	make -C "$dir" PREFIX=/usr/local MANDIR=/share/man/man1 install >>"$logfile" 2>&1 || return 1
	relabel
}

# The heaviest build in the script. Deliberately non-fatal: lf falls back to
# chafa previews, and losing previews is much better than losing the install.
build_ueberzugpp() {
	for dep in $ueberzugppdeps; do
		installpkg "$dep" || printf "ueberzugpp dep unavailable: %s\\n" "$dep" >>"$logfile"
	done
	dir="$repodir/ueberzugpp"
	rm -rf "$dir"
	sudo -u "$name" -H git -C "$repodir" clone --depth 1 --single-branch \
		--no-tags -q -b "$ueberzugpptag" "$ueberzugpprepo" "$dir" >>"$logfile" 2>&1 ||
		{
			printf "tag %s unavailable, falling back to the default branch\\n" "$ueberzugpptag" >>"$logfile"
			sudo -u "$name" -H git -C "$repodir" clone --depth 1 --single-branch \
				--no-tags -q "$ueberzugpprepo" "$dir" >>"$logfile" 2>&1
		} || return 1
	sudo -u "$name" -H env HOME="/home/$name" sh -c "cd '$dir' && cmake -B build \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
		-DENABLE_OPENCV=OFF -DENABLE_WAYLAND=OFF -DENABLE_X11=ON" >>"$logfile" 2>&1 || return 1
	sudo -u "$name" -H env HOME="/home/$name" \
		sh -c "cd '$dir' && cmake --build build -j$(nproc)" >>"$logfile" 2>&1 || return 1
	cmake --install "$dir/build" >>"$logfile" 2>&1 || return 1
	# The Arch package ships this symlink. lfub and .config/lf/scope both call
	# `ueberzug`, so providing it means those dotfiles need no Fedora-specific edit.
	ln -sf /usr/local/bin/ueberzugpp /usr/local/bin/ueberzug
	relabel
}

### REPOSITORIES ###

enablerpmfusion() {
	rpm -q --quiet rpmfusion-free-release && rpm -q --quiet rpmfusion-nonfree-release && return 0
	whiptail --infobox "Enabling RPM Fusion..." 7 40
	logmsg "rpmfusion"
	freeurl="https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$fedver.noarch.rpm"
	nonfreeurl="https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$fedver.noarch.rpm"
	# Deliberately NOT fatal. A third-party mirror being down must not strand
	# someone part-way through installing a machine that has no other OS on it.
	# The cost of skipping is limited codec support, which is recoverable later.
	curl -sfI "$freeurl" >/dev/null 2>&1 || {
		notework "RPM Fusion (no release package for Fedora $fedver yet; full ffmpeg codecs unavailable)"
		return 1
	}
	# --nogpgcheck: the RPM Fusion signing key is not trusted until the release
	# package that ships it is installed. This is the documented bootstrap, and
	# it is an explicit trust decision -- see RUNBOOK.md.
	dnf -y install --nogpgcheck "$freeurl" "$nonfreeurl" >>"$logfile" 2>&1 || {
		notework "RPM Fusion (could not enable; full ffmpeg codecs unavailable)"
		return 1
	}
}

# Fedora ships ffmpeg-free, which has no H.264/H.265/AAC encoders. Swapped here,
# before anything links against libav*, so the resolver works on a clean slate.
swapffmpeg() {
	rpm -q --quiet ffmpeg && return 0
	whiptail --infobox "Swapping in the full ffmpeg build..." 7 50
	logmsg "ffmpeg swap"
	dnf -y swap ffmpeg-free ffmpeg --allowerasing >>"$logfile" 2>&1 ||
		dnf -y install ffmpeg --allowerasing >>"$logfile" 2>&1 ||
		notework "ffmpeg swap (codec support will be limited)"
}

enablelibrewolfrepo() {
	[ -f /etc/yum.repos.d/librewolf.repo ] && return 0
	whiptail --infobox "Enabling the LibreWolf repository..." 7 50
	logmsg "librewolf repo"
	# Also not fatal, for the same reason: a browser must never be able to abort
	# the installation of an entire machine. If the repo is unreachable the L
	# rows are skipped and everything else proceeds.
	curl -fsSL https://repo.librewolf.net/librewolf.repo \
		-o /etc/yum.repos.d/librewolf.repo >>"$logfile" 2>&1 || {
		rm -f /etc/yum.repos.d/librewolf.repo
		notework "LibreWolf repository unreachable (browser will not be installed)"
		return 1
	}
	dnf -y makecache --refresh >>"$logfile" 2>&1
	[ -n "$(dnf -q repoquery librewolf 2>/dev/null)" ] || {
		rm -f /etc/yum.repos.d/librewolf.repo
		notework "LibreWolf repository offers no librewolf package (browser will not be installed)"
		return 1
	}
}

# Extensions come from policy, not from packages: Fedora has no equivalent of
# the AUR librewolf-extension-* packages. GUIDs are the addons' real IDs -- a
# wrong one fails silently, so they were taken from the AMO API.
librewolfpolicies() {
	mkdir -p /etc/librewolf/policies
	cat >/etc/librewolf/policies/policies.json <<-'POLICIES'
	{
	  "policies": {
	    "ExtensionSettings": {
	      "uBlock0@raymondhill.net": {
	        "installation_mode": "force_installed",
	        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
	      },
	      "{b86e4813-687a-43e6-ab65-0bde4ab75758}": {
	        "installation_mode": "force_installed",
	        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/localcdn-fork-of-decentraleyes/latest.xpi"
	      },
	      "idcac-pub@guus.ninja": {
	        "installation_mode": "force_installed",
	        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/istilldontcareaboutcookies/latest.xpi"
	      },
	      "tridactyl.vim@cmcaine.co.uk": {
	        "installation_mode": "force_installed",
	        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/tridactyl-vim/latest.xpi"
	      }
	    },
	    "DisableTelemetry": true,
	    "DisablePocket": true,
	    "DisableFirefoxStudies": true,
	    "NoDefaultBookmarks": true
	  }
	}
	POLICIES
	chmod 0644 /etc/librewolf/policies/policies.json
}

# Generates the browser profile so arkenfox + larbs.js can be written into it.
# Upstream sleeps one second and hopes; on a slow VM that is a coin flip and the
# failure is silent, so this polls instead.
librewolfprofile() {
	command -v librewolf >/dev/null 2>&1 || return 0
	whiptail --infobox "Generating the browser profile..." 7 50
	logmsg "librewolf profile"
	browserdir="/home/$name/.librewolf"
	profilesini="$browserdir/profiles.ini"

	sudo -u "$name" -H librewolf --headless >>"$logfile" 2>&1 &

	profile=""
	i=0
	while [ "$i" -lt 60 ]; do
		if [ -f "$profilesini" ]; then
			profile="$(sed -n '/Default=.*\.default-default/ s/.*=//p' "$profilesini" 2>/dev/null)"
			[ -n "$profile" ] && [ -d "$browserdir/$profile" ] && break
			profile=""
		fi
		sleep 1
		i=$((i + 1))
	done

	pkill -u "$name" -f librewolf >/dev/null 2>&1
	sleep 2
	pkill -9 -u "$name" -f librewolf >/dev/null 2>&1

	if [ -n "$profile" ] && [ -d "$browserdir/$profile" ]; then
		makeuserjs "$browserdir/$profile"
	else
		# Not fatal: extensions come from policies.json and need no profile.
		notework "librewolf profile (arkenfox user.js not installed; extensions are unaffected)"
	fi
}

makeuserjs() {
	pdir="$1"
	arkenfox="$pdir/arkenfox.js"
	overrides="$pdir/user-overrides.js"
	userjs="$pdir/user.js"
	ln -fs "/home/$name/.config/firefox/larbs.js" "$overrides"
	sudo -u "$name" -H curl -sfL "$arkenfoxurl" -o "$arkenfox" >>"$logfile" 2>&1 || {
		notework "arkenfox user.js download"
		return 1
	}
	cat "$arkenfox" "$overrides" >"$userjs"
	chown "$name":"$name" "$arkenfox" "$userjs"
	sudo -u "$name" -H mkdir -p "$pdir/chrome"
}

### SYSTEM CONFIGURATION ###

adduserandpass() {
	whiptail --infobox "Adding user \"$name\"..." 7 50
	# Fedora uses user private groups. wheel is supplementary (-G), never the
	# primary group (-g) as on Arch, or every file this user creates would be
	# group-owned by wheel.
	# video is needed on real hardware: brightnessctl's udev rule hands backlight
	# control to that group, and without it screen brightness keys do nothing.
	useradd -m -G wheel,video -s /bin/zsh "$name" >>"$logfile" 2>&1 ||
		usermod -a -G wheel,video "$name" >>"$logfile" 2>&1
	mkdir -p "/home/$name"
	chown "$name":"$name" "/home/$name"
	export repodir="/home/$name/.local/src"
	mkdir -p "$repodir"
	chown -R "$name":"$name" "/home/$name/.local"
	echo "$name:$pass1" | chpasswd
	unset pass1 pass2
}

# $1 = drop-in name, $2 = contents.
newperms() {
	# sudo silently ignores any file in sudoers.d whose name contains a dot, and
	# the only symptom is a build hanging forever on a password prompt.
	case "$1" in
	*.*) error "Internal error: sudoers drop-in name '$1' contains a dot." ;;
	esac
	tmp="$(mktemp)"
	printf "%s\\n" "$2" >"$tmp"
	chmod 0440 "$tmp"
	visudo -cf "$tmp" >/dev/null 2>&1 || {
		rm -f "$tmp"
		error "Refusing to install an invalid sudoers file: $1"
	}
	install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/$1" || {
		rm -f "$tmp"
		error "Could not install /etc/sudoers.d/$1"
	}
	rm -f "$tmp"
	# A bad drop-in breaks all sudo, including the recovery you would need.
	visudo -c >/dev/null 2>&1 || {
		rm -f "/etc/sudoers.d/$1"
		error "Installing $1 broke the sudoers tree, so it was removed."
	}
}

putgitrepo() {
	whiptail --infobox "Downloading and installing config files..." 7 60
	logmsg "dotfiles"
	[ -z "$3" ] && branch="master" || branch="$repobranch"
	# Staged inside the user's own home rather than /tmp, so nothing depends on
	# SELinux type transitions behaving correctly for a copy across filesystems.
	dir="/home/$name/.cache/larbs-dotfiles"
	rm -rf "$dir"
	mkdir -p "$dir" "$2"
	chown -R "$name":"$name" "$dir" "$2"
	# --recurse-submodules is load-bearing: without it .config/mpv/script_modules
	# is empty and pauseallmpv silently stops working.
	sudo -u "$name" -H git clone --depth 1 --single-branch --no-tags -q \
		--recurse-submodules --shallow-submodules -b "$branch" "$1" "$dir" >>"$logfile" 2>&1 ||
		error "Could not clone $1 (branch $branch). Check the URL and that the branch exists."

	src="$dir"
	[ -n "$dotfilesdir" ] && src="$dir/$dotfilesdir"
	[ -d "$src" ] ||
		error "The repository has no directory '$dotfilesdir'. Pass -d with the subdirectory that holds .config and .local."
	# Guard against pointing -r at a repository root that holds the installer
	# and the dotfiles side by side. Without this the copy below would put
	# directories into $HOME instead of dotfiles, and the first symptom would be
	# a user logging in to a bare shell with nothing configured.
	[ -d "$src/.config" ] ||
		error "No .config directory in ${dotfilesdir:-the repository root}. If the installer and the dotfiles share one repository, pass the dotfiles subdirectory with -d (for example: -d voidrice)."

	sudo -u "$name" -H cp -rfT "$src" "$2" ||
		error "Could not copy the dotfiles into $2."
	rm -rf "$dir"
}

# The five dotfiles git stores as symlinks are the whole session entry path. If
# the repo was ever committed from a Windows checkout without core.symlinks,
# they arrive as plain text files and the user logs in to a bare shell with no
# explanation anywhere.
checksymlinks() {
	for f in .zprofile .xprofile .xinitrc .gtkrc-2.0; do
		[ -e "/home/$name/$f" ] || continue
		[ -L "/home/$name/$f" ] && continue
		error "/home/$name/$f is a regular file but must be a symlink. The dotfiles repo was committed from a checkout without core.symlinks. Fix it in the repo (git ls-files -s should show mode 120000) and re-run."
	done
}

vimplugininstall() {
	whiptail --infobox "Installing neovim plugins..." 7 60
	logmsg "vim-plug"
	mkdir -p "/home/$name/.config/nvim/autoload"
	curl -sfL "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim" \
		>"/home/$name/.config/nvim/autoload/plug.vim" 2>>"$logfile" || {
		notework "vim-plug download"
		return 1
	}
	chown -R "$name":"$name" "/home/$name/.config/nvim"
	sudo -u "$name" -H nvim -c "PlugInstall|q|q" >>"$logfile" 2>&1
}

relabel() {
	command -v restorecon >/dev/null 2>&1 || return 0
	restorecon -RF /usr/local/bin /usr/local/share >>"$logfile" 2>&1
	return 0
}

systemdsetup() {
	whiptail --infobox "Configuring services..." 7 40
	logmsg "systemd"
	systemctl set-default multi-user.target >>"$logfile" 2>&1
	systemctl enable --now crond >>"$logfile" 2>&1
	# `systemctl --user enable` is impossible for a user with no session: there
	# is no user bus to talk to and no XDG_RUNTIME_DIR yet. --global writes to
	# /etc/systemd/user and applies to every future session.
	systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service >>"$logfile" 2>&1
	# The packaged system daemon would bind :9091 and fight the per-user daemon
	# that transadd and td-toggle start.
	systemctl disable --now transmission-daemon >>"$logfile" 2>&1
	rpm -q --quiet initial-setup &&
		systemctl disable --now initial-setup.service initial-setup-text.service >>"$logfile" 2>&1
	return 0
}

installationloop() {
	tmpprogs="$(mktemp)"
	readprogs "$tmpprogs"
	total=$(wc -l <"$tmpprogs")

	# Check third-party repo preconditions once, up front, and skip those rows if
	# unmet. Otherwise a missing repo shows up as a run of identical "No match
	# for argument" failures with no indication of the actual cause. Skipping
	# rather than aborting keeps a dead third-party mirror from taking the whole
	# installation down with it.
	skipf=0
	skipl=0
	if grep -q '^F,' "$tmpprogs" && ! rpm -q --quiet rpmfusion-free-release; then
		notework "all F rows skipped: RPM Fusion is not enabled"
		skipf=1
	fi
	if grep -q '^L,' "$tmpprogs" && [ ! -f /etc/yum.repos.d/librewolf.repo ]; then
		notework "all L rows skipped: the LibreWolf repository is not configured"
		skipl=1
	fi

	n=0
	# Read on fd 3: on the shared stdin of upstream's loop, make and git can and
	# do swallow CSV rows.
	while IFS=, read -r tag program comment <&3; do
		n=$((n + 1))
		echo "$comment" | grep -q "^\".*\"$" &&
			comment="$(echo "$comment" | sed -E "s/(^\"|\"$)//g")"
		case "$tag" in
		G) gitmakeinstall "$program" "$comment" ;;
		R) recipeinstall "$program" "$comment" ;;
		P) pipxinstall "$program" "$comment" ;;
		F) [ "$skipf" = 1 ] || maininstall "$program" "$comment" ;;
		L) [ "$skipl" = 1 ] || maininstall "$program" "$comment" ;;
		*) maininstall "$program" "$comment" ;;
		esac
	done 3<"$tmpprogs"
	rm -f "$tmpprogs"
}

### MAIN ###

checkhost

[ "$dryrun" -eq 1 ] && resolve

: >"$logfile" 2>/dev/null || error "Could not write to $logfile."
failedlist="$(mktemp)"

# whiptail comes from `newt` on Fedora, not `libnewt`. Nothing below works
# without it, so it is the very first package.
dnf -y install newt >>"$logfile" 2>&1 ||
	error "Could not install newt (whiptail). Check the network and that this is Fedora."

welcomemsg || error "User exited."
getuserandpass || error "User exited."
usercheck || error "User exited."
preinstallmsg || error "User exited."

whiptail --infobox "Refreshing package metadata..." 7 40
dnf -y upgrade --refresh >>"$logfile" 2>&1

for x in $bootstrappkgs; do
	whiptail --title "Fedora LARBS Installation" \
		--infobox "Installing \`$x\` which is required to install and configure other programs." 8 70
	installpkg "$x" || notework "bootstrap: $x"
done

# chrony before any repository key import: a skewed clock on a fresh VM fails
# TLS validation and RPM signature checks in ways that look like network errors.
systemctl enable --now chronyd >>"$logfile" 2>&1
command -v chronyc >/dev/null 2>&1 && chronyc makestep >>"$logfile" 2>&1

adduserandpass || error "Error adding username and/or password."

# Signals must actually stop the run. Previously the handler cleaned up and the
# installer carried on, so Ctrl-C looked like it did nothing while quietly
# removing the passwordless-sudo rule the rest of the run depends on.
trap 'rm -f /etc/sudoers.d/larbstemp; exit 1' HUP INT QUIT TERM
trap 'rm -f /etc/sudoers.d/larbstemp' EXIT
newperms larbstemp "%wheel ALL=(ALL) NOPASSWD: ALL
Defaults:%wheel,root runcwd=*"

# Fedora's dmenu is vanilla and lacks the -P flag that dmenupass needs as the
# SUDO_ASKPASS handler. /usr/local/bin precedes /usr/bin so the fork would win
# anyway, but leaving both installed is a trap for whoever debugs this later.
rpm -q --quiet dmenu && dnf -y remove dmenu >>"$logfile" 2>&1

enablerpmfusion
swapffmpeg
enablelibrewolfrepo

installationloop
relabel

putgitrepo "$dotfilesrepo" "/home/$name" "$repobranch"
rm -rf "/home/$name/.git/" "/home/$name/README.md" "/home/$name/LICENSE" \
	"/home/$name/FUNDING.yml" "/home/$name/.gitattributes" "/home/$name/.gitmodules"
checksymlinks

vimplugininstall

sudo -u "$name" -H mkdir -p "/home/$name/.cache/zsh" \
	"/home/$name/.config/mpd/playlists" "/home/$name/.local/share/mpd"

# chsh lives in util-linux-user, which is not in @core, so upstream's chsh call
# would silently do nothing here.
usermod -s /bin/zsh "$name" >>"$logfile" 2>&1

# Upstream runs neither. Without update-desktop-database, xdg-open cannot
# resolve the .desktop files the dotfiles just installed, which breaks
# linkhandler and opout.
fc-cache -f >>"$logfile" 2>&1

# Verify the emoji font actually landed. Without it every status bar module
# still prints its value but its icon is silently dropped, so the bar looks
# like a row of bare numbers and the scripts look broken when they are fine.
# The monochrome font is the one the status bar actually depends on: dwm's
# fallback glyph search sets FC_COLOR=FcFalse, so it will not accept the colour
# emoji font and every bar icon renders as nothing while the numbers still show.
fc-list 2>/dev/null | grep -qi "NotoEmoji-" ||
	notework "google-noto-emoji-fonts (status bar icons will NOT render; dnf install it and run fc-cache -f)"
fc-list 2>/dev/null | grep -qi "NotoColorEmoji" ||
	notework "google-noto-color-emoji-fonts (colour emoji in the terminal will not render)"
fc-list 2>/dev/null | grep -qi "font awesome" ||
	notework "fontawesome-fonts-all (some status bar glyphs will not render)"
command -v update-desktop-database >/dev/null 2>&1 &&
	update-desktop-database "/home/$name/.local/share/applications" >>"$logfile" 2>&1

# Most important command! Get rid of the beep!
rmmod pcspkr >/dev/null 2>&1
printf "blacklist pcspkr\\nblacklist snd_pcsp\\n" >/etc/modprobe.d/nobeep.conf

# Must come after installationloop: on @core, /etc/X11 does not exist until the
# X server is installed. Named 99- because Fedora ships its own libinput snippet
# at /usr/share/X11/xorg.conf.d/40-libinput.conf and files merge in lexical order.
mkdir -p /etc/X11/xorg.conf.d
[ -f /etc/X11/xorg.conf.d/99-touchpad.conf ] || cat >/etc/X11/xorg.conf.d/99-touchpad.conf <<-'TOUCHPAD'
	Section "InputClass"
	        Identifier "touchpad"
	        MatchIsTouchpad "on"
	        Option "Tapping" "on"
	        Option "NaturalScrolling" "false"
	EndSection
TOUCHPAD

librewolfpolicies
librewolfprofile

newperms 01-larbs-cmds-without-password "%wheel ALL=(ALL:ALL) NOPASSWD: /usr/sbin/shutdown,/usr/sbin/reboot,/usr/sbin/poweroff,/usr/bin/systemctl suspend,/usr/bin/systemctl hibernate,/usr/bin/mount,/usr/bin/umount,/usr/bin/loadkeys,/usr/bin/dnf upgrade --downloadonly -y,/usr/bin/dnf -y upgrade"
newperms 02-larbs-visudo-editor "Defaults editor=/usr/bin/nvim"

# The filename must end in .conf or systemd-sysctl silently ignores it. Fedora
# builds the kernel with CONFIG_SECURITY_DMESG_RESTRICT, so unlike on Arch this
# setting is actually doing something.
mkdir -p /etc/sysctl.d
printf "kernel.dmesg_restrict = 0\\n" >/etc/sysctl.d/99-larbs-dmesg.conf
sysctl --system >>"$logfile" 2>&1

systemdsetup
relabel

rm -f /etc/sudoers.d/larbstemp
trap - HUP INT QUIT TERM EXIT

finalize
rm -f "$failedlist"
clear
