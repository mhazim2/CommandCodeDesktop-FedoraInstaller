#!/usr/bin/env bash
#
# install-command-code.sh
#
# Install the "Command Code" desktop app (Electron) from its upstream .deb on
# Fedora-family systems. The .deb is unpacked directly with `ar` + `tar`
# (no dpkg needed), so this works equally on:
#
#   * immutable ostree/bootc hosts (Fedora Silverblue/Kinoite, Bazzite,
#     RakuOS, ...) -> per-user install under ~/.local (no root needed);
#   * ordinary mutable hosts (Fedora, RHEL, CentOS Stream, AlmaLinux,
#     Rocky Linux, Oracle Linux, ...) -> system-wide install under /usr/local
#     (uses sudo).
#
# Idempotent: re-running replaces the existing install cleanly.
#
# Safety model:
#   * The new .deb is fully extracted and validated in a temp/staging area
#     BEFORE the working install is touched.
#   * If anything is wrong (incomplete download, corrupt archive, wrong
#     architecture, missing libraries, unexpected layout...) the installer
#     STOPS, explains the problem, and leaves your current install untouched.
#   * On a terminal it pauses at the end so you can read the message.
#
# Usage:
#   ./install-command-code.sh                    # newest deb from ~/Downloads
#   ./install-command-code.sh path/to/app.deb     # a specific deb
#   ./install-command-code.sh --user              # force per-user install
#   ./install-command-code.sh --system            # force system-wide install
#   ./install-command-code.sh --uninstall
#   ./install-command-code.sh --help
#
# Options:
#   --user          install per-user (~/.local), no root needed
#   --system        install system-wide (/usr/local), uses sudo
#   --no-verify     skip the md5 integrity check (faster)
#   --force         install even if shared libraries are missing
#   --no-pause      never wait for Enter on failure (for scripts/cron)
#
set -Eeuo pipefail

APP_ID="command-code"
APP_NAME="Command Code"
DOWNLOAD_GLOB="CommandCode-*-amd64.deb"

HOME_DIR="${HOME:?HOME is not set}"
DATA_HOME="${XDG_DATA_HOME:-$HOME_DIR/.local/share}"
DOWNLOAD_DIR="$HOME_DIR/Downloads"
OVERLAY_PKGS_LIST="/var/lib/rakuos/packages.list"

# Upstream release feed (Electron-builder latest-linux.yml lists the .deb with
# its filename, size and sha512).
DEB_UPSTREAM_REPO="CommandCodeAI/desktop"
RELEASE_META_URL="https://github.com/$DEB_UPSTREAM_REPO/releases/latest/download/latest-linux.yml"
RELEASE_DL_BASE="https://github.com/$DEB_UPSTREAM_REPO/releases/latest/download"

DEB=""
DO_UNINSTALL=0
VERIFY=1
FORCE=0
AUTO_DOWNLOAD=0
NO_PAUSE="${CC_NO_PAUSE:-0}"
SCOPE=""          # user | system ; empty = auto-detect
SUDO=""           # set to "sudo" when a system install needs elevation

# resolved by set_paths()
OPT_DIR="" BIN_DIR="" DESKTOP_DIR="" DESKTOP_FILE="" ICON_ROOT=""

# OS info (filled from /etc/os-release)
OS_ID="" OS_LIKE="" OS_PLATFORM="" OS_PRETTY=""

FAILED=0
TMP=""
STAGE=""

# ---- output helpers ----------------------------------------------------------
log()  { printf '  %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
note() { printf '\033[36m·\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }

# Run a command, elevating with sudo for a system-wide install when needed.
run() {
	if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi
}

pause_on_failure() {
	[ "$NO_PAUSE" = 1 ] && return 0
	# Only pause if we can actually open a controlling terminal; otherwise
	# (scripts, CI) never block.
	if ( exec </dev/tty ) 2>/dev/null; then
		printf '\nPress Enter to close... ' >&2
		read -r _ < /dev/tty 2>/dev/null || true
	fi
}

# fail "summary" ["detail line" ...]  -> stop, explain, pause, exit non-zero
fail() {
	local summary="$1"; shift || true
	FAILED=1
	{
		printf '\n\033[31m✗ Installation stopped: %s\033[0m\n' "$summary"
		local line
		for line in "$@"; do
			[ -n "$line" ] && printf '    %s\n' "$line"
		done
		if [ -n "$OPT_DIR" ] && [ -x "$OPT_DIR/$APP_ID" ]; then
			printf '    \033[2mYour existing install is intact: %s\033[0m\n' "$OPT_DIR"
		fi
	} >&2
	pause_on_failure
	exit 1
}

on_err() {
	local code=$?
	local line="${1:-?}"
	if [ "$FAILED" -eq 1 ]; then
		exit "$code"
	fi
	FAILED=1
	printf '\n\033[31m✗ Installation stopped: unexpected error (exit %s) near line %s\033[0m\n' \
		"$code" "$line" >&2
	printf '    %s\n' "This is likely a bug in the installer. Nothing was swapped into place." >&2
	if [ -n "$OPT_DIR" ] && [ -x "$OPT_DIR/$APP_ID" ]; then
		printf '    \033[2mYour existing install is intact: %s\033[0m\n' "$OPT_DIR" >&2
	fi
	pause_on_failure
	exit "$code"
}

cleanup() {
	[ -n "$TMP" ] && rm -rf "$TMP"
	if [ -n "$STAGE" ]; then run rm -rf "$STAGE" || true; fi
	return 0
}
trap 'on_err "$LINENO"' ERR
trap cleanup EXIT

# ---- host / distro detection -------------------------------------------------
if [ -r /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	OS_ID="${ID:-}"
	OS_LIKE="${ID_LIKE:-}"
	OS_PLATFORM="${PLATFORM_ID:-}"
	OS_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"
fi

host_machine="$(uname -m)"
case "$host_machine" in
	x86_64)  host_deb_arch="amd64" ;;
	aarch64) host_deb_arch="arm64" ;;
	i386|i686) host_deb_arch="i386" ;;
	*)       host_deb_arch="$host_machine" ;;
esac

# Immutable = /usr is read-only and managed as an image (ostree/bootc).
is_immutable() {
	[ -e /run/ostree-booted ] && return 0
	[ -d /run/ostree/.private ] && return 0
	[ -e /sysroot/ostree ] && return 0
	[ -w /usr ] || return 0
	return 1
}

# Enterprise Linux family (RHEL, CentOS, Alma, Rocky, Oracle, ...).
is_el() {
	case "$OS_PLATFORM" in platform:el[0-9]*) return 0 ;; esac
	case "$OS_ID" in rhel|centos|almalinux|rocky|ol|oraclelinux) return 0 ;; esac
	case " $OS_LIKE " in *" rhel "*) return 0 ;; esac
	return 1
}

# The command that installs packages on this host (for dependency hints).
pkg_install_cmd() {
	if   command -v rum        >/dev/null 2>&1; then echo "sudo rum install"
	elif command -v rpm-ostree >/dev/null 2>&1; then echo "sudo rpm-ostree install"
	elif command -v dnf        >/dev/null 2>&1; then echo "sudo dnf install"
	elif command -v microdnf   >/dev/null 2>&1; then echo "sudo microdnf install"
	elif command -v yum        >/dev/null 2>&1; then echo "sudo yum install"
	else echo ""; fi
}

# Set OPT_DIR/BIN_DIR/... for the chosen scope.
set_paths() {
	if [ "$SCOPE" = system ]; then
		OPT_DIR="/usr/local/opt/$APP_ID"
		BIN_DIR="/usr/local/bin"
		DESKTOP_DIR="/usr/local/share/applications"
		ICON_ROOT="/usr/local/share/icons/hicolor"
	else
		OPT_DIR="$HOME_DIR/.local/opt/$APP_ID"
		BIN_DIR="$HOME_DIR/.local/bin"
		DESKTOP_DIR="$DATA_HOME/applications"
		ICON_ROOT="$DATA_HOME/icons/hicolor"
	fi
	DESKTOP_FILE="$DESKTOP_DIR/$APP_ID.desktop"
}

resolve_scope() {
	[ -n "$SCOPE" ] || { if is_immutable; then SCOPE=user; else SCOPE=system; fi; }
	set_paths
}

prepare_privileges() {
	SUDO=""
	[ "$SCOPE" = system ] || return 0
	if [ "$(id -u)" -eq 0 ]; then return 0; fi
	if command -v sudo >/dev/null 2>&1; then
		SUDO="sudo"
		if ! "$SUDO" -v 2>/dev/null; then
			fail "sudo authentication failed" \
				"A system-wide install needs root. Re-run as root, or use --user."
		fi
		return 0
	fi
	fail "a system-wide install needs root" \
		"Re-run as root, or use --user for a per-user install."
}

# User-namespace support (lets Electron sandbox without a setuid helper).
userns_ok() {
	[ -L /proc/self/ns/user ] || return 1
	if command -v unshare >/dev/null 2>&1; then
		unshare --user true 2>/dev/null
	else
		return 0
	fi
}

# ---- downloading the latest release ------------------------------------------
# Fetch URL -> FILE using curl or wget.
fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q --tries=3 -O "$2" "$1"
	else
		return 127
	fi
}

# Base64 of a file's sha512 (matches the value published in latest-linux.yml).
sha512_b64() {
	if command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha512 -binary "$1" | base64 -w0 2>/dev/null
	elif command -v sha512sum >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1; then
		sha512sum "$1" | awk '{print $1}' | xxd -r -p | base64 -w0 2>/dev/null
	else
		return 1
	fi
}

# Prompt on the controlling terminal (defaults to yes). Non-interactive -> no.
ask_yes_no() {
	local ans
	[ "$NO_PAUSE" = 1 ] && return 1
	( exec </dev/tty ) 2>/dev/null || return 1
	printf '%s [Y/n] ' "$1" >&2
	read -r ans < /dev/tty 2>/dev/null || return 1
	case "$ans" in ''|y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# Download the newest published .deb into $DOWNLOAD_DIR.
#   $1 = "force" (skip prompt) or "ask" (prompt first)
# On success prints the path on stdout; messages go to stderr.
download_latest_deb() {
	local mode="${1:-ask}" meta deb_name ver url dest sha size human got
	if [ "$host_deb_arch" != amd64 ]; then
		warn "no .deb is published for this host ($host_deb_arch); upstream ships a linux x86_64 .deb only"
		return 1
	fi
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		warn "need curl or wget to download the .deb"
		return 1
	fi

	meta="$TMP/latest-linux.yml"
	if ! fetch "$RELEASE_META_URL" "$meta"; then
		warn "could not fetch release metadata ($RELEASE_META_URL)"
		return 1
	fi
	ver="$(sed -n 's/^version: *//p' "$meta" | head -n1 || true)"
	deb_name="$(grep -oE 'CommandCode-[^ ]+-amd64\.deb' "$meta" | head -n1 || true)"
	if [ -z "$deb_name" ]; then
		warn "no linux .deb is listed in the latest release"
		return 1
	fi
	sha="$(awk -v n="$deb_name" '$1=="-"&&$2=="url:"{c=$3} c==n&&$1=="sha512:"{print $2; exit}' "$meta" || true)"
	size="$(awk -v n="$deb_name" '$1=="-"&&$2=="url:"{c=$3} c==n&&$1=="size:"{print $2; exit}' "$meta" || true)"

	if [ "$mode" = ask ]; then
		human=""
		[ -n "$size" ] && human=", ~$(( size / 1048576 )) MB"
		if ! ask_yes_no "No .deb found in $DOWNLOAD_DIR. Download $deb_name (${ver:+v$ver }latest$human) now?"; then
			return 2
		fi
	fi

	mkdir -p "$DOWNLOAD_DIR"
	dest="$DOWNLOAD_DIR/$deb_name"
	url="$RELEASE_DL_BASE/$deb_name"
	note "downloading $deb_name ..." >&2
	if ! fetch "$url" "$dest.part"; then
		warn "download failed"
		rm -f "$dest.part"
		return 3
	fi

	if [ -n "$sha" ]; then
		if got="$(sha512_b64 "$dest.part")"; then
			if [ "$got" != "$sha" ]; then
				warn "downloaded file failed its sha512 check (corrupt/partial download)"
				rm -f "$dest.part"
				return 3
			fi
		else
			warn "could not verify sha512 (openssl/base64 missing) — continuing"
		fi
	fi

	mv -f "$dest.part" "$dest"
	printf '%s' "$dest"
}

usage() {
	resolve_scope
	cat <<EOF
$APP_NAME installer (idempotent)

Usage:
  $(basename "$0") [DEB_PATH]        Install from DEB_PATH (default: newest
                                     $DOWNLOAD_GLOB in $DOWNLOAD_DIR)
  $(basename "$0") --deb DEB_PATH    Install from an explicit .deb path
  $(basename "$0") --uninstall       Remove the install (see --user/--system)
  $(basename "$0") --help            Show this help

Options:
  --user        install per-user under ~/.local (no root)
  --system      install system-wide under /usr/local (uses sudo)
  --download    download the latest .deb from GitHub and install it (no prompt)
  --no-verify   skip the md5 integrity check
  --force       install even if shared libraries are missing
  --no-pause    do not wait for Enter when something fails

Host: ${OS_PRETTY:-unknown}
$( if is_immutable; then echo "  immutable image -> default scope is --user"; else echo "  mutable host    -> default scope is --system"; fi )
Packages are installed with: $(pkg_install_cmd || echo "(no known package manager)")

With the detected/default scope ($SCOPE), this installs to:
  app     $OPT_DIR
  binary  $BIN_DIR/$APP_ID  (symlink)
  menu    $DESKTOP_FILE
  icons   $ICON_ROOT/*/apps/$APP_ID.png
EOF
}

refresh_caches() {
	if command -v update-desktop-database >/dev/null 2>&1; then
		run update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
	fi
	if command -v gtk-update-icon-cache >/dev/null 2>&1; then
		run gtk-update-icon-cache -f -t "$ICON_ROOT" >/dev/null 2>&1 || true
	fi
	if command -v xdg-mime >/dev/null 2>&1; then
		xdg-mime default "$APP_ID.desktop" x-scheme-handler/commandcode >/dev/null 2>&1 || true
	fi
}

# ---- dependency helpers ------------------------------------------------------
# Debian package name -> Fedora/RPM package name (the ones Electron apps need).
# The same names apply on RHEL/CentOS Stream/Alma/Rocky (libappindicator-gtk3
# lives in EPEL there).
map_debian_dep() {
	case "$1" in
		libgtk-3-0|libgtk-3-0t64)      echo gtk3 ;;
		libnotify4)                     echo libnotify ;;
		libnss3)                        echo nss ;;
		libxss1)                        echo libXScrnSaver ;;
		libxtst6)                       echo libXtst ;;
		xdg-utils)                      echo xdg-utils ;;
		libatspi2.0-0|libatspi2.0-0t64) echo at-spi2-core ;;
		libuuid1)                       echo libuuid ;;
		libsecret-1-0)                  echo libsecret ;;
		libasound2|libasound2t64)       echo alsa-lib ;;
		libappindicator3-1)             echo libappindicator-gtk3 ;;
		*) ;;
	esac
}

# Emit the Fedora/RPM package names required by a .deb control file.
collect_required_pkgs() {
	local control="$1" field line token alt
	[ -f "$control" ] || return 0
	for field in Depends Recommends; do
		line="$(sed -n "s/^$field: *//p" "$control" | head -n1 || true)"
		[ -n "$line" ] || continue
		while IFS= read -r token; do
			token="${token%%(*}"                     # drop "(>= 1.2)"
			token="$(printf '%s' "$token" | tr -d ' ')"
			[ -n "$token" ] || continue
			while IFS= read -r alt; do               # a | b alternatives
				alt="$(printf '%s' "$alt" | tr -d ' ')"
				[ -n "$alt" ] && map_debian_dep "$alt"
			done < <(printf '%s\n' "$token" | tr '|' '\n')
		done < <(printf '%s\n' "$line" | tr ',' '\n')
	done
}

# Map a missing shared library (e.g. libnss3.so) to an installable package
# name. Uses `rum provides` on RakuOS and `dnf repoquery` elsewhere. Falls back
# to the raw soname if it can't be resolved.
resolve_so_to_pkg() {
	local so="$1" cands="" n filtered="" shortest
	if command -v rum >/dev/null 2>&1; then
		cands="$(rum provides "${so}()(64bit)" 2>/dev/null \
			| sed -nE 's/^([^ ]+)-[0-9][^-]*-[^-]*\.(x86_64|noarch|i686|aarch64).*/\1/p' \
			| sort -u || true)"
	elif command -v dnf >/dev/null 2>&1; then
		cands="$(timeout 30 dnf -q repoquery --whatprovides "${so}()(64bit)" 2>/dev/null \
			| sed -nE 's/^([^ ]+)-[0-9][^-]*-[^-]*\.(x86_64|noarch|i686|aarch64).*/\1/p' \
			| sort -u || true)"
	fi
	if [ -z "$cands" ]; then printf '%s' "$so"; return; fi
	# Drop packages the user already installed via the overlay (e.g. a browser
	# that bundles its own copy of the soname) — they are already present.
	while IFS= read -r n; do
		[ -n "$n" ] || continue
		if [ -f "$OVERLAY_PKGS_LIST" ] && grep -qx "$n" "$OVERLAY_PKGS_LIST" 2>/dev/null; then
			continue
		fi
		filtered="${filtered}${n}"$'\n'
	done <<< "$cands"
	[ -n "$filtered" ] || filtered="$cands"
	shortest="$(printf '%s' "$filtered" | awk 'NF{print length, $0}' | sort -n | head -n1 | cut -d' ' -f2- || true)"
	printf '%s' "${shortest:-$so}"
}

# Print a ready-to-run install command for the given (space-separated) packages.
print_suggestion() {
	local list="$1" cmd
	[ -n "$list" ] || return 0
	# shellcheck disable=SC2086
	set -- $list
	cmd="$(pkg_install_cmd)"
	printf '    \033[1mSuggested fix:\033[0m\n'
	if [ -z "$cmd" ]; then
		printf '      install these packages, then re-run: %s\n' "$*"
		return 0
	fi
	printf '      %s %s\n' "$cmd" "$*"
	case "$cmd" in
		*sudo*rum*)        printf '      \033[2m(rum adds this to the RakuOS overlay; persists across image updates)\033[0m\n' ;;
		*sudo*rpm-ostree*) printf '      \033[2m(layers into the image; takes effect after a reboot)\033[0m\n' ;;
		*) ;;
	esac
	if is_el; then
		case " $* " in
			*" libappindicator-gtk3 "*) printf '      \033[2m(libappindicator-gtk3 is in EPEL — enable it first if needed)\033[0m\n' ;;
		esac
	fi
}

do_uninstall() {
	echo "Uninstalling $APP_NAME ($SCOPE install)..."
	run rm -rf "$OPT_DIR"
	run rm -f  "$BIN_DIR/$APP_ID"
	run rm -f  "$DESKTOP_FILE"
	if [ -d "$ICON_ROOT" ]; then
		run find "$ICON_ROOT" -type f -name "$APP_ID.png" -delete 2>/dev/null || true
	fi
	refresh_caches
	ok "Removed $APP_NAME"
}

# ---- parse arguments ---------------------------------------------------------
while [ "$#" -gt 0 ]; do
	case "$1" in
		--uninstall)  DO_UNINSTALL=1; shift ;;
		--user)       SCOPE=user; shift ;;
		--system)     SCOPE=system; shift ;;
		--download)   AUTO_DOWNLOAD=1; shift ;;
		--deb)        [ "$#" -ge 2 ] || fail "--deb requires a path" ; DEB="$2"; shift 2 ;;
		--no-verify)  VERIFY=0; shift ;;
		--force)      FORCE=1; shift ;;
		--no-pause)   NO_PAUSE=1; shift ;;
		-h|--help)    usage; exit 0 ;;
		-*)           fail "unknown option: $1" "Try --help." ;;
		*)            DEB="$1"; shift ;;
	esac
done

resolve_scope

if [ "$DO_UNINSTALL" -eq 1 ]; then
	prepare_privileges
	do_uninstall
	exit 0
fi

prepare_privileges

TMP="$(mktemp -d)"

# ---- locate the .deb ---------------------------------------------------------
if [ -z "$DEB" ]; then
	if [ "$AUTO_DOWNLOAD" -eq 1 ]; then
		dest="$(download_latest_deb force)" || dest=""
		if [ -z "$dest" ]; then
			fail "could not download the latest .deb" \
				"Check your network connection, or download it manually and pass a path."
		fi
		DEB="$dest"
		log "downloaded: $DEB"
	else
		shopt -s nullglob
		candidates=( "$DOWNLOAD_DIR"/$DOWNLOAD_GLOB )
		shopt -u nullglob
		if [ "${#candidates[@]}" -eq 0 ]; then
			# Nothing downloaded yet — offer to fetch the latest release.
			if dest="$(download_latest_deb ask)"; then
				DEB="$dest"
				log "downloaded: $DEB"
			else
				fail "no matching .deb found in $DOWNLOAD_DIR" \
					"Looked for: $DOWNLOAD_GLOB" \
					"Download it manually, pass a path, or re-run with --download."
			fi
		else
			newest=""
			for f in "${candidates[@]}"; do
				if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
					newest="$f"
				fi
			done
			DEB="$newest"
		fi
	fi
fi

# ---- preflight: the file and the tools --------------------------------------
[ -f "$DEB" ] || fail "file not found: $DEB"
[ -s "$DEB" ] || fail "the .deb is empty (0 bytes): $DEB" \
	"The download looks incomplete — re-download it and try again."

for tool in ar tar md5sum; do
	command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

echo "Installing $APP_NAME from:"
log "$DEB"
if is_immutable; then host_kind="immutable image"; else host_kind="mutable host"; fi
note "host: ${OS_PRETTY:-unknown} ($host_kind) — scope: $SCOPE"
[ "$SCOPE" = system ] && note "elevating with sudo as needed (target: /usr/local)"

# ---- unpack the outer ar archive --------------------------------------------
if ! members="$( cd "$TMP" && ar t "$DEB" 2>/dev/null )"; then
	fail "this is not a readable .deb (ar failed)" \
		"The file may be corrupt or only partially downloaded." \
		"Re-download it and try again."
fi
printf '%s\n' "$members" | grep -qx 'debian-binary' || fail "not a valid .deb (no debian-binary member)" \
	"The download looks corrupt — re-download it."
data_member_name="$( printf '%s\n' "$members" | grep -m1 '^data.tar\.' || true )"
[ -n "$data_member_name" ] || fail "not a valid .deb (no data.tar.* member)" \
	"The download looks corrupt or incomplete — re-download it."

( cd "$TMP" && ar x "$DEB" ) || fail "failed to extract the .deb archive" \
	"The file may be corrupt — re-download it."

# ---- read control metadata ---------------------------------------------------
pkg_version="" arch=""
control_member="$(find "$TMP" -maxdepth 1 -name 'control.tar.*' -print -quit)"
if [ -n "$control_member" ]; then
	mkdir -p "$TMP/control"
	if tar -xf "$control_member" -C "$TMP/control" 2>/dev/null && [ -f "$TMP/control/control" ]; then
		pkg_version="$(sed -n 's/^Version: *//p'   "$TMP/control/control" | head -n1)"
		arch="$(sed -n 's/^Architecture: *//p' "$TMP/control/control" | head -n1)"
	fi
fi

# fall back to the filename for the version label
if [ -z "$pkg_version" ]; then
	deb_base="$(basename "$DEB")"
	pkg_version="${deb_base#CommandCode-}"; pkg_version="${pkg_version%-amd64.deb}"
fi
[ -n "$pkg_version" ] && log "version: $pkg_version"

# architecture guard
if [ -n "$arch" ] && [ "$arch" != "all" ] && [ "$arch" != "$host_deb_arch" ]; then
	fail "wrong architecture: the package is '$arch' but this host is '$host_deb_arch' ($host_machine)" \
		"Download the '$host_deb_arch' build instead."
fi

# ---- unpack the payload archive ---------------------------------------------
mkdir -p "$TMP/data"
if ! tar -xf "$TMP/$data_member_name" -C "$TMP/data" 2>/dev/null; then
	fail "failed to unpack $data_member_name" \
		"The archive is corrupt or the download is incomplete." \
		"Re-download the .deb and try again."
fi

# ---- integrity check (catches silent corruption / partial downloads) ---------
if [ "$VERIFY" -eq 1 ]; then
	if [ -f "$TMP/control/md5sums" ]; then
		if ! ( cd "$TMP/data" && md5sum -c --quiet --status "$TMP/control/md5sums" ) 2>/dev/null; then
			bad="$( ( cd "$TMP/data" && md5sum -c "$TMP/control/md5sums" 2>/dev/null ) | grep -v ': OK$' | head -n5 || true )"
			fail "integrity check failed — the download is corrupt or incomplete" \
				"$bad" \
				"Re-download the .deb, or re-run with --no-verify to skip this check."
		fi
		note "integrity verified ($(wc -l < "$TMP/control/md5sums") files)"
	else
		warn "package has no md5sums; skipping integrity check"
	fi
else
	warn "integrity check skipped (--no-verify)"
fi

# ---- find the app payload ----------------------------------------------------
APP_SRC=""
if [ -d "$TMP/data/opt/$APP_NAME" ]; then
	APP_SRC="$TMP/data/opt/$APP_NAME"
else
	while IFS= read -r d; do
		if [ -x "$d/$APP_ID" ]; then APP_SRC="$d"; break; fi
	done < <(find "$TMP/data/opt" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
fi
if [ -z "$APP_SRC" ]; then
	found="$(ls -1 "$TMP/data/opt" 2>/dev/null | paste -sd', ' - || true)"
	fail "could not find the app payload inside the .deb" \
		"Expected 'opt/$APP_NAME' (or a directory containing an executable '$APP_ID')." \
		"Found under opt/: ${found:-<nothing>}" \
		"The package layout may have changed upstream."
fi

[ -x "$APP_SRC/$APP_ID" ] || fail "the executable '$APP_ID' is missing from the payload" \
	"Expected: $APP_ID next to the other app files." \
	"The package layout may have changed upstream."

# ---- dependencies: declared packages + missing shared libraries --------------
declare -a required_pkgs_arr=()
while IFS= read -r p; do
	[ -n "$p" ] && required_pkgs_arr+=("$p")
done < <(collect_required_pkgs "$TMP/control/control" 2>/dev/null | awk 'NF' | sort -u || true)

missing_pkgs=""
if command -v rpm >/dev/null 2>&1; then
	for p in "${required_pkgs_arr[@]:-}"; do
		[ -n "$p" ] || continue
		rpm -q --quiet "$p" 2>/dev/null || missing_pkgs="${missing_pkgs}${p}"$'\n'
	done
fi

missing_libs=""
if command -v ldd >/dev/null 2>&1; then
	missing_libs="$( ldd "$APP_SRC/$APP_ID" 2>/dev/null | awk '/not found/{print $1}' | sort -u || true )"
fi

# Build a suggested package list: resolve each missing soname, plus any declared
# dependency that isn't installed. Sonames that no repo provides are reported
# separately (they can't be turned into an install command).
resolve_list=""
unresolved_list=""
while IFS= read -r so; do
	[ -n "$so" ] || continue
	pkg="$(resolve_so_to_pkg "$so")"
	if [ "$pkg" = "$so" ]; then
		unresolved_list="${unresolved_list}${so}"$'\n'
	else
		resolve_list="${resolve_list}${pkg}"$'\n'
	fi
done <<< "$missing_libs"
suggest="$(printf '%s\n%s\n' "$resolve_list" "$missing_pkgs" | awk 'NF' | sort -u || true)"

print_unresolved() {
	[ -n "$unresolved_list" ] || return 0
	printf '    \033[1mNot provided by any repo:\033[0m\n' >&2
	printf '%s\n' "$unresolved_list" | awk 'NF' | sed 's/^/      - /' >&2
	printf '      \033[2m(this library has to be obtained another way)\033[0m\n' >&2
}

if [ -n "$missing_libs" ]; then
	if [ "$FORCE" -eq 1 ]; then
		warn "missing shared libraries (continuing because of --force):"
		printf '%s\n' "$missing_libs" | awk 'NF' | sed 's/^/      - /' >&2
		print_suggestion "$suggest" >&2
		print_unresolved
	else
		FAILED=1
		{
			printf '\n\033[31m✗ Installation stopped: required libraries are missing\033[0m\n'
			printf '    The app would likely fail to start on this version:\n'
			printf '%s\n' "$missing_libs" | awk 'NF' | sed 's/^/      - /'
			printf '    \033[2mYour existing install is intact: %s\033[0m\n' "$OPT_DIR"
		} >&2
		print_unresolved
		print_suggestion "$suggest" >&2
		pause_on_failure
		exit 1
	fi
elif [ -n "$missing_pkgs" ]; then
	warn "some declared dependencies are not installed (the app starts without them, but some features may be limited)"
	printf '%s\n' "$missing_pkgs" | awk 'NF' | sed 's/^/      - /' >&2
	print_suggestion "$suggest" >&2
fi

# ---- stage the new payload (do not touch the working install yet) ------------
run mkdir -p "$(dirname "$OPT_DIR")"
STAGE="$(dirname "$OPT_DIR")/.$APP_ID.stage"
run rm -rf "$STAGE"
run mkdir -p "$STAGE"
run cp -a "$APP_SRC/." "$STAGE/"
[ -x "$STAGE/$APP_ID" ] || fail "staging failed: '$APP_ID' is not executable after copy"

# Sandbox: prefer the kernel namespace sandbox; fall back to a setuid helper on
# a system install; otherwise the app must run with --no-sandbox.
EXEC_ARGS=""
if userns_ok; then
	run chmod 0755 "$STAGE/chrome-sandbox" 2>/dev/null || true
elif [ "$SCOPE" = system ]; then
	run chown root:root "$STAGE/chrome-sandbox"
	run chmod 4755 "$STAGE/chrome-sandbox"
	note "user namespaces unavailable — using the setuid chrome-sandbox helper"
else
	EXEC_ARGS="--no-sandbox "
	warn "user namespaces are unavailable and this is a per-user install, so the"
	warn "Electron sandbox cannot be enabled; the launcher will pass --no-sandbox."
	warn "For proper sandboxing re-run with: $(basename "$0") --system"
fi

# ---- install icons ----------------------------------------------------------
installed_icons=0
if [ -d "$TMP/data/usr/share/icons/hicolor" ]; then
	for dir in "$TMP/data/usr/share/icons/hicolor"/*/apps; do
		[ -f "$dir/$APP_ID.png" ] || continue
		icon_size="$(basename "$(dirname "$dir")")"
		run mkdir -p "$ICON_ROOT/$icon_size/apps"
		run cp -a "$dir/$APP_ID.png" "$ICON_ROOT/$icon_size/apps/"
		installed_icons=$((installed_icons + 1))
	done
fi

# ---- desktop entry ----------------------------------------------------------
run mkdir -p "$DESKTOP_DIR"
tmp_desktop="$TMP/$APP_ID.desktop"
cat > "$tmp_desktop" <<EOF
[Desktop Entry]
Name=$APP_NAME
Comment=$APP_NAME desktop app
Exec=$OPT_DIR/$APP_ID ${EXEC_ARGS}%U
TryExec=$OPT_DIR/$APP_ID
Terminal=false
Type=Application
Icon=$APP_ID
StartupWMClass=$APP_ID
MimeType=x-scheme-handler/commandcode;
Categories=Development;
EOF
run cp -f "$tmp_desktop" "$DESKTOP_FILE"

# ---- binary ------------------------------------------------------------
run mkdir -p "$BIN_DIR"
run ln -sf "$OPT_DIR/$APP_ID" "$BIN_DIR/$APP_ID"

# ---- swap in the new payload (last, with rollback) --------------------------
BACKUP="$(dirname "$OPT_DIR")/.$APP_ID.bak"
run rm -rf "$BACKUP"
if [ -e "$OPT_DIR" ]; then
	run mv "$OPT_DIR" "$BACKUP" || fail "could not move the old install aside"
fi
if ! run mv "$STAGE" "$OPT_DIR"; then
	[ -e "$BACKUP" ] && run mv "$BACKUP" "$OPT_DIR"
	fail "failed to move the new payload into place" "Your previous install was restored."
fi
run rm -rf "$BACKUP"
STAGE=""

# ---- caches / mime ----------------------------------------------------------
refresh_caches

ok "Installed $APP_NAME ${pkg_version:+$pkg_version }($SCOPE) to $OPT_DIR"
echo
log "binary : $BIN_DIR/$APP_ID"
log "menu   : $DESKTOP_FILE"
log "icons  : $installed_icons size(s)"
echo
echo "Launch from the app menu, or run: $BIN_DIR/$APP_ID"
case ":$PATH:" in
	*":$BIN_DIR:"*) ;;
	*) warn "$BIN_DIR is not in your PATH; add it to use the 'command-code' command." ;;
esac
