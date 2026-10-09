# Command Code installer (Fedora-family, multi-distro)

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

A self-contained, idempotent installer for the **Command Code** desktop app
(Electron). Upstream ships a Debian `.deb`; this unpacks it directly (a `.deb`
is just an `ar` archive containing `control.tar.*` + `data.tar.*`) and installs
it on RPM-based, **Fedora-family** systems — no `dpkg` needed.

## Supported hosts

| Host type | Examples | Install scope | Root |
| --- | --- | --- | --- |
| **Immutable** image (ostree/bootc) | Fedora Silverblue/Kinoite, Bazzite, RakuOS | per-user under `~/.local` | no |
| **Mutable** host | Fedora, RHEL, CentOS Stream, AlmaLinux, Rocky Linux, Oracle Linux | system-wide under `/usr/local` | `sudo` |

The default scope is chosen automatically:

- `/usr` is read-only (or `/run/ostree-booted` exists, or `rpm-ostree` is
  present) → **per-user**, so nothing has to fight the read-only image.
- Otherwise → **system-wide** under `/usr/local` (uses `sudo`).

Override with `--user` or `--system` at any time.

## Quick start

```bash
cd ~/Projects/CommandCodeDesktop-FedoraInstaller
./install-command-code.sh                 # newest CommandCode-*.deb in ~/Downloads
```

Specific file, or a forced scope:

```bash
./install-command-code.sh ~/Downloads/CommandCode-0.1.51-amd64.deb
./install-command-code.sh --deb /path/to/CommandCode-x.y.z-amd64.deb
./install-command-code.sh --user          # force per-user
./install-command-code.sh --system        # force system-wide (sudo)
./install-command-code.sh --download      # fetch the latest .deb and install it
```

If there's **no `.deb` in `~/Downloads`**, the installer offers to download the
newest release from GitHub (`CommandCodeAI/desktop`) into `~/Downloads` and
continues with it. The prompt shows the version and size, and defaults to yes:

```
No .deb found in ~/Downloads. Download CommandCode-0.1.51-amd64.deb (v0.1.51 latest, ~120 MB) now? [Y/n]
```

It fetches the release's `latest-linux.yml` to learn the exact filename and
**sha512**, verifies the download against it, then installs. In a
non-interactive context (no terminal) it won't prompt — use `--download` to
fetch the latest without asking, or it fails with a hint.

Flags:

| Flag | Meaning |
| --- | --- |
| `--user` / `--system` | force the install scope |
| `--download` | download the latest `.deb` from GitHub and install it (no prompt) |
| `--no-verify` | skip the md5 integrity check |
| `--force` | install even if shared libraries are missing |
| `--no-pause` | never wait for Enter when something fails |

Launch **Command Code** from the app menu, or run `command-code`
(per-user: `~/.local/bin/command-code`, system: `/usr/local/bin/command-code`).

> If the menu entry doesn't appear immediately, log out and back in (or restart
> your launcher) so it re-reads the XDG desktop database.

## What gets installed

**Per-user (`--user`, default on immutable hosts):**

| Item | Path |
| --- | --- |
| App payload | `~/.local/opt/command-code/` |
| CLI binary | `~/.local/bin/command-code` → symlink |
| Menu entry | `~/.local/share/applications/command-code.desktop` |
| Icons | `~/.local/share/icons/hicolor/*/apps/command-code.png` |

**System-wide (`--system`, default on mutable hosts):**

| Item | Path |
| --- | --- |
| App payload | `/usr/local/opt/command-code/` |
| CLI binary | `/usr/local/bin/command-code` → symlink |
| Menu entry | `/usr/local/share/applications/command-code.desktop` |
| Icons | `/usr/local/share/icons/hicolor/*/apps/command-code.png` |

`/usr/local/...` is used (rather than `/opt` + `/usr/share`) so nothing is
tangled up with RPM-managed files. The desktop entry's `Exec` points at the
absolute binary path, and the `x-scheme-handler/commandcode` MIME type is
registered.

## When a new download is broken

The new `.deb` is unpacked and checked in a temporary area **before** your
working install is touched, so a bad download can never leave you with a
half-installed app. The installer stops, explains the problem, and — on a
terminal — waits for you to press Enter so you can read it.

It stops like that when it finds:

- the file is missing or **0 bytes** (incomplete download),
- the file is **not a valid `.deb`**, or the archive is corrupt/truncated,
- the payload **fails the md5 integrity check** (silent corruption),
- the package targets a **different architecture** than this host,
- the **app layout changed** upstream (payload dir / executable not found),
- the app needs **shared libraries that aren't installed** on this host.

On any of these, the existing install is left exactly as it was:

```
✗ Installation stopped: integrity check failed — the download is corrupt or incomplete
    opt/Command Code/command-code: FAILED
    Re-download the .deb, or re-run with --no-verify to skip this check.
    Your existing install is intact: /usr/local/opt/command-code
```

Without a terminal (e.g. from a script) it never blocks — it just exits
non-zero with the same message on stderr.

## Dependencies & libraries

Before swapping anything in, the installer checks the app's requirements:

- It reads the `.deb`'s `Depends:`/`Recommends:`, translates the Debian names
  to their RPM equivalents (`libnss3` → `nss`, `libgtk-3-0` → `gtk3`,
  `libxss1` → `libXScrnSaver`, `libasound2` → `alsa-lib`, …), and checks each
  with `rpm -q`.
- It runs `ldd` on the app binary and collects anything **not found**.

Then:

- **A hard library is missing** (the app would not start) → it stops, lists the
  libraries, and prints a ready-to-run install command. Each missing soname is
  resolved to a package (`rum provides` on RakuOS, `dnf repoquery` elsewhere);
  anything no repo provides is listed separately.
- **Only declared-but-optional deps are missing** (the app starts anyway) → a
  non-fatal warning with the same suggestion.

The suggested command matches the host's package manager:

| Package manager | Host | Command |
| --- | --- | --- |
| `rum` | RakuOS (overlay, persists across image updates) | `sudo rum install …` |
| `rpm-ostree` | Fedora Silverblue/Kinoite, CoreOS | `sudo rpm-ostree install …` (reboot) |
| `dnf` | Fedora, RHEL 8+, CentOS Stream, Alma, Rocky | `sudo dnf install …` |
| `yum` | RHEL/CentOS 7 | `sudo yum install …` |

On Enterprise Linux, `libappindicator-gtk3` lives in **EPEL**; the script notes
this when it would be needed. Use `--force` to skip the hard stop and install
anyway.

Example output (RakuOS):

```
! some declared dependencies are not installed (the app starts without them, but some features may be limited)
      - libappindicator-gtk3
      - libXScrnSaver
    Suggested fix:
      sudo rum install libappindicator-gtk3 libXScrnSaver
      (rum adds this to the RakuOS overlay; persists across image updates)
```

## Sandbox

Electron's sandbox needs either user namespaces or a setuid helper:

- **User namespaces available** (most modern Fedora/RHEL 8+ with the default
  kernel settings) → `chrome-sandbox` is left `0755` and the kernel namespace
  sandbox is used. No root, no setuid.
- **User namespaces unavailable, system install** → `chrome-sandbox` is made
  root-owned and mode `4755` (the upstream approach).
- **User namespaces unavailable, per-user install** → the sandbox can't be
  enabled, so the desktop entry is written with `--no-sandbox` and a warning is
  printed. Re-run with `--system` if you want proper sandboxing.

## Updating

Same command — re-running is fully idempotent and replaces the previous
install in place:

```bash
./install-command-code.sh          # picks up the newest .deb in ~/Downloads
```

Remove the install directory first is **not** required; the script does that for
you.

## Uninstalling

```bash
./install-command-code.sh --uninstall            # removes the detected/default scope
./install-command-code.sh --system --uninstall    # removes the system-wide install
./install-command-code.sh --user --uninstall      # removes the per-user install
```

This removes the payload, the symlink, the menu entry, and the icons, then
refreshes the caches.

## How it works

1. Detects the host (immutable vs mutable), the distro, and the package manager,
   then selects the scope and target paths.
2. Locates the `.deb` (newest in `~/Downloads`, or one you pass in).
3. Unpacks it with `ar x` into a temp dir, then `tar -xf`s the `data.tar.*`
   member (xz/gz/zst auto-detected).
4. Validates it: architecture, an md5 integrity pass over every file, and the
   shared-library / declared-dependency checks.
5. Stages the payload next to the install, then atomically swaps it in
   (restoring the old copy if the swap fails).
6. Installs the icons and the `.desktop` entry, symlinks the binary, and
   refreshes `update-desktop-database` / `gtk-update-icon-cache` / `xdg-mime`.

Steps 5–6 are elevated with `sudo` for a system-wide install. The temp dir is
removed on exit, and nothing is swapped into place until every check passes.

## Notes & troubleshooting

- **RHEL/CentOS/Alma/Rocky**: the runtime library names match Fedora, so the
  dependency mapping works as-is; `libappindicator-gtk3` is in EPEL.
- **`vaInitialize failed: unknown libva error`** on startup is a harmless
  GPU/VA-API warning; the app falls back to software rendering and works fine.
- **Command not found in a shell**: add `~/.local/bin` (or `/usr/local/bin`) to
  your `PATH`.
- **No menu entry**: validate the desktop file with
  `desktop-file-validate <path>/command-code.desktop`.

## Files here

- `install-command-code.sh` — the idempotent installer (install / update / uninstall).
- `README.md` — this document.
- `LICENSE` — MIT.

## License

MIT — see [LICENSE](LICENSE). This covers the installer script in this
repository; the Command Code app it installs remains under its own upstream
license.
