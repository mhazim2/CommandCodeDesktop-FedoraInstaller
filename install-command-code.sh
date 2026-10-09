#!/usr/bin/env bash
#
# install-command-code.sh
#
# Install the "Command Code" desktop app (Electron) from its upstream .deb
# onto an immutable bootc/ostree Fedora host, per-user (no root required).
#
# The host image is read-only (/usr is a composefs overlay) and has no dpkg,
# so this extracts the .deb directly with `ar` + `tar` and lays the payload
# out under ~/.local, where the XDG launcher picks it up.
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
#   ./install-command-code.sh                  # newest deb from ~/Downloads
#   ./install-command-code.sh path/to/app.deb   # a specific deb
#   ./install-command-code.sh --deb app.deb     # same, explicit flag
#   ./install-command-code.sh --uninstall       # remove the per-user install
#   ./install-command-code.sh --help
#
# Options:
#   --no-verify     skip the md5 integrity check (faster)
#   --force         install even if libraries are missing / unknowns are found
#   --no-pause      never wait for Enter on failure (for scripts/cron)
#
set -Eeuo pipefail

APP_ID="command-code"
APP_NAME="Command Code"
DOWNLOAD_GLOB="CommandCode-*-amd64.deb"

HOME_DIR="${HOME:?HOME is not set}"
DATA_HOME="${XDG_DATA_HOME:-$HOME_DIR/.local/share}"

OPT_DIR="$HOME_DIR/.local/opt/$APP_ID"
BIN_DIR="$HOME_DIR/.local/bin"
DESKTOP_DIR="$DATA_HOME/applications"
DESKTOP_FILE="$DESKTOP_DIR/$APP_ID.desktop"
ICON_ROOT="$DATA_HOME/icons/hicolor"
DOWNLOAD_DIR="$HOME_DIR/Downloads"
OVERLAY_PKGS_LIST="/var/lib/rakuos/packages.list"

DEB=""
DO_UNINSTALL=0
VERIFY=1
FORCE=0
NO_PAUSE="${CC_NO_PAUSE:-0}"

FAILED=0
TMP=""
STAGE=""

# ---- output helpers ----------------------------------------------------------
log()  { printf '  %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
note() { printf '\033[36m·\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }

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
	[ -n "$STAGE" ] && rm -rf "$STAGE"
	return 0
}
trap 'on_err "$LINENO"' ERR
trap cleanup EXIT

usage() {
	cat <<EOF
$APP_NAME installer (per-user, idempotent)

Usage:
  $(basename "$0") [DEB_PATH]        Install from DEB_PATH (default: newest
                                     $DOWNLOAD_GLOB in $DOWNLOAD_DIR)
  $(basename "$0") --deb DEB_PATH    Install from an explicit .deb path
  $(basename "$0") --uninstall       Remove the per-user install
  $(basename "$0") --help            Show this help

Options:
  --no-verify   skip the md5 integrity check
  --force       install even if shared libraries are missing
  --no-pause    do not wait for Enter when something fails

Installs to:
  app     $OPT_DIR
  binary  $BIN_DIR/$APP_ID  (symlink)
  menu    $DESKTOP_FILE
  icons   $ICON_ROOT/*/apps/$APP_ID.png
EOF
}

refresh_caches() {
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
	fi
	if command -v gtk-update-icon-cache >/dev/null 2>&1; then
		gtk-update-icon-cache -f -t "$ICON_ROOT" >/dev/null 2>&1 || true
	fi
	if command -v xdg-mime >/dev/null 2>&1; then
		xdg-mime default "$APP_ID.desktop" x-scheme-handler/commandcode >/dev/null 2>&1 || true
	fi
}

# ---- dependency helpers ------------------------------------------------------
# Debian package name -> Fedora/RPM package name (the ones Electron apps need).
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

# Emit the Fedora package names required by a .deb control file (Depends + Recommends).
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

# Map a missing shared library (e.g. libnss3.so) to an installable package name
# using `rum provides`. Falls back to the raw soname if it can't be resolved.
resolve_so_to_pkg() {
	local so="$1" cands="" n filtered="" shortest
	if ! command -v rum >/dev/null 2>&1; then printf '%s' "$so"; return; fi
	cands="$(rum provides "${so}()(64bit)" 2>/dev/null \
		| sed -nE 's/^([^ ]+)-[0-9][^-]*-[^-]*\.(x86_64|noarch|i686|aarch64).*/\1/p' \
		| sort -u || true)"
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
	local list="$1"
	[ -n "$list" ] || return 0
	# shellcheck disable=SC2086
	set -- $list
	printf '    \033[1mSuggested fix:\033[0m\n'
	if command -v rpm-ostree >/dev/null 2>&1; then
		printf '      sudo rpm-ostree install %s\n' "$*"
		printf '      \033[2m(layers into the image; takes effect after a reboot)\033[0m\n'
	elif command -v rum >/dev/null 2>&1; then
		printf '      sudo rum install %s\n' "$*"
		printf '      \033[2m(rum adds this to the RakuOS overlay; persists across image updates)\033[0m\n'
	elif command -v dnf >/dev/null 2>&1; then
		printf '      sudo dnf install %s\n' "$*"
	else
		printf '      install these packages, then re-run: %s\n' "$*"
	fi
}

do_uninstall() {
	echo "Uninstalling $APP_NAME (per-user)..."
	rm -rf "$OPT_DIR"
	rm -f  "$BIN_DIR/$APP_ID"
	rm -f  "$DESKTOP_FILE"
	if [ -d "$ICON_ROOT" ]; then
		find "$ICON_ROOT" -type f -name "$APP_ID.png" -delete 2>/dev/null || true
	fi
	refresh_caches
	ok "Removed $APP_NAME"
}

# ---- parse arguments ---------------------------------------------------------
while [ "$#" -gt 0 ]; do
	case "$1" in
		--uninstall)  DO_UNINSTALL=1; shift ;;
		--deb)        [ "$#" -ge 2 ] || fail "--deb requires a path" ; DEB="$2"; shift 2 ;;
		--no-verify)  VERIFY=0; shift ;;
		--force)      FORCE=1; shift ;;
		--no-pause)   NO_PAUSE=1; shift ;;
		-h|--help)    usage; exit 0 ;;
		-*)           fail "unknown option: $1" "Try --help." ;;
		*)            DEB="$1"; shift ;;
	esac
done

if [ "$DO_UNINSTALL" -eq 1 ]; then
	do_uninstall
	exit 0
fi

# ---- locate the .deb ---------------------------------------------------------
if [ -z "$DEB" ]; then
	shopt -s nullglob
	candidates=( "$DOWNLOAD_DIR"/$DOWNLOAD_GLOB )
	shopt -u nullglob
	if [ "${#candidates[@]}" -eq 0 ]; then
		fail "no matching .deb found in $DOWNLOAD_DIR" \
			"Looked for: $DOWNLOAD_GLOB" \
			"Download a new Command Code .deb, or pass a path explicitly."
	fi
	newest=""
	for f in "${candidates[@]}"; do
		if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
			newest="$f"
		fi
	done
	DEB="$newest"
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

TMP="$(mktemp -d)"

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
pkg_version="" arch="" pkg_name=""
control_member="$(find "$TMP" -maxdepth 1 -name 'control.tar.*' -print -quit)"
if [ -n "$control_member" ]; then
	mkdir -p "$TMP/control"
	if tar -xf "$control_member" -C "$TMP/control" 2>/dev/null && [ -f "$TMP/control/control" ]; then
		pkg_name="$(sed -n 's/^Package: *//p'      "$TMP/control/control" | head -n1)"
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
host_machine="$(uname -m)"
case "$host_machine" in
	x86_64)  host_deb_arch="amd64" ;;
	aarch64) host_deb_arch="arm64" ;;
	i386|i686) host_deb_arch="i386" ;;
	*)       host_deb_arch="$host_machine" ;;
esac
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
mkdir -p "$(dirname "$OPT_DIR")"
STAGE="$(dirname "$OPT_DIR")/.$APP_ID.stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$APP_SRC/." "$STAGE/"
# leave the sandbox non-setuid so Electron uses the kernel namespace sandbox
chmod 0755 "$STAGE/chrome-sandbox" 2>/dev/null || true
[ -x "$STAGE/$APP_ID" ] || fail "staging failed: '$APP_ID' is not executable after copy"

# ---- install icons ----------------------------------------------------------
installed_icons=0
if [ -d "$TMP/data/usr/share/icons/hicolor" ]; then
	for dir in "$TMP/data/usr/share/icons/hicolor"/*/apps; do
		[ -f "$dir/$APP_ID.png" ] || continue
		icon_size="$(basename "$(dirname "$dir")")"
		mkdir -p "$ICON_ROOT/$icon_size/apps"
		cp -a "$dir/$APP_ID.png" "$ICON_ROOT/$icon_size/apps/"
		installed_icons=$((installed_icons + 1))
	done
fi

# ---- desktop entry ----------------------------------------------------------
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=$APP_NAME
Comment=$APP_NAME desktop app
Exec=$OPT_DIR/$APP_ID %U
TryExec=$OPT_DIR/$APP_ID
Terminal=false
Type=Application
Icon=$APP_ID
StartupWMClass=$APP_ID
MimeType=x-scheme-handler/commandcode;
Categories=Development;
EOF

# ---- user binary ------------------------------------------------------------
mkdir -p "$BIN_DIR"
ln -sf "$OPT_DIR/$APP_ID" "$BIN_DIR/$APP_ID"

# ---- swap in the new payload (last, with rollback) --------------------------
BACKUP="$(dirname "$OPT_DIR")/.$APP_ID.bak"
rm -rf "$BACKUP"
if [ -e "$OPT_DIR" ]; then
	mv "$OPT_DIR" "$BACKUP" || fail "could not move the old install aside"
fi
if ! mv "$STAGE" "$OPT_DIR"; then
	[ -e "$BACKUP" ] && mv "$BACKUP" "$OPT_DIR"
	fail "failed to move the new payload into place" "Your previous install was restored."
fi
rm -rf "$BACKUP"
STAGE=""

# ---- caches / mime ----------------------------------------------------------
refresh_caches

ok "Installed $APP_NAME ${pkg_version:+$pkg_version }to $OPT_DIR"
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
