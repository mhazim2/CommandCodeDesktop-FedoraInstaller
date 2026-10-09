# Command Code — per-user install on an immutable host

This directory contains a self-contained, idempotent installer for the
**Command Code** desktop app (Electron) on this machine.

## Why an installer instead of `dpkg`/`rpm`

This host is an **immutable bootc / ostree image** (Fedora-based):

- `/usr` is a read-only `composefs` overlay — you cannot drop files into
  `/usr`, `/opt`, `/etc` or `/usr/local` without a root-owned image change.
- There is **no `dpkg`**, and no `rpm-ostree` for layering local packages
  (the system uses `bootc`).
- Upstream ships a Debian `.deb`, which we can still unpack directly — a
  `.deb` is just an `ar` archive containing `control.tar.*` + `data.tar.*`.

So the app is installed **per-user under `~/.local`**, which is writable,
survives OS updates, needs no root, and is picked up by the XDG app launcher.

All of the Electron runtime libraries (`libnss3`, `libgtk-3`, `libasound`,
`libsecret`, `libatspi`, etc.) are already present in the base image — the
binary reports no missing shared libraries.

## Quick start

```bash
cd ~/"Command Code"
./install-command-code.sh
```

By default it installs the **newest** `CommandCode-*-amd64.deb` found in
`~/Downloads`. To install a specific file:

```bash
./install-command-code.sh ~/Downloads/CommandCode-0.1.51-amd64.deb
./install-command-code.sh --deb /path/to/CommandCode-x.y.z-amd64.deb
```

Extra flags: `--no-verify` (skip the md5 integrity check), `--force` (install
even if shared libraries are missing), `--no-pause` (never wait for Enter).

Then launch **Command Code** from the app menu, or run:

```bash
~/.local/bin/command-code
```

> If the menu entry doesn't appear immediately, log out and back in (or
> restart your launcher) so it re-reads the XDG desktop database.

## What gets installed

| Item        | Path                                                     |
| ----------- | -------------------------------------------------------- |
| App payload | `~/.local/opt/command-code/`                             |
| CLI binary  | `~/.local/bin/command-code` → symlink                    |
| Menu entry  | `~/.local/share/applications/command-code.desktop`       |
| Icons       | `~/.local/share/icons/hicolor/*/apps/command-code.png`   |

The `Exec` line in the desktop entry points at the absolute binary path, and
the `x-scheme-handler/commandcode` MIME type is registered.

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

On any of these, the existing `~/.local/opt/command-code` is left exactly as
it was:

```
✗ Installation stopped: integrity check failed — the download is corrupt or incomplete
    opt/Command Code/command-code: FAILED
    Re-download the .deb, or re-run with --no-verify to skip this check.
    Your existing install is intact: /var/home/rakuos/.local/opt/command-code
```

Without a terminal (e.g. from a script) it never blocks — it just exits
non-zero with the same message on stderr.

## Dependencies & libraries

Before swapping anything in, the installer checks that the app's requirements
are satisfied on this host:

- It reads the `.deb`'s `Depends:`/`Recommends:` fields, translates the Debian
  package names to their Fedora equivalents (`libnss3` → `nss`, `libgtk-3-0` →
  `gtk3`, `libxss1` → `libXScrnSaver`, …), and checks each with `rpm -q`.
- It runs `ldd` on the app binary and collects anything reported as
  **not found**.

What it does with that:

- **A hard library is missing** (the app would not start) → it stops, lists the
  libraries, and prints a ready-to-run command. It also resolves each missing
  soname to an installable package with `rum provides` (e.g. `libXss.so.1` →
  `libXScrnSaver`); anything no repo provides is listed separately.
- **Only declared-but-optional deps are missing** (the app starts anyway, some
  features may be limited) → a non-fatal warning with the same suggestion.

Example output:

```
! some declared dependencies are not installed (the app starts without them, but some features may be limited)
      - libappindicator-gtk3
      - libXScrnSaver
    Suggested fix:
      sudo rum install libappindicator-gtk3 libXScrnSaver
      (rum adds this to the RakuOS overlay; persists across image updates)
```

Because this host layers packages with **`rum`** (into the RakuOS overlay), the
suggested command is `sudo rum install …` and the result survives OS image
updates. On hosts using `rpm-ostree` or plain `dnf` the script prints the
matching command instead. Use `--force` to skip the hard stop and install
anyway.

## Updating

Same command — re-running is fully idempotent and replaces the previous
install in place:

```bash
./install-command-code.sh          # picks up the newest .deb in ~/Downloads
```

Remove `~/.local/opt/command-code` first is **not** required; the script does
that for you.

## Uninstalling

```bash
./install-command-code.sh --uninstall
```

This removes the payload, the symlink, the menu entry, and the icons, then
refreshes the caches.

## How it works

1. Locates the `.deb` (newest in `~/Downloads`, or one you pass in).
2. Unpacks it with `ar x` into a temp dir, then `tar -xf`s the
   `data.tar.*` member (xz/gz/zst are auto-detected).
3. Validates it: architecture, an md5 integrity pass over every file, and a
   check that the app's shared libraries are present.
4. Stages the payload next to the install, then atomically swaps it into
   `~/.local/opt/command-code/` (restoring the old copy if the swap fails).
5. Installs the hicolor icons and the `.desktop` entry, symlinks
   `~/.local/bin/command-code`, and refreshes
   `update-desktop-database` / `gtk-update-icon-cache` / `xdg-mime`.

The temp dir is removed automatically on exit, and nothing is swapped into
place until every check has passed.

## Notes & troubleshooting

- **`chrome-sandbox`** is left mode `0755` (not setuid). This host has
  unprivileged user namespaces enabled, so Electron uses the kernel namespace
  sandbox — no root and no setuid bit needed.
- **`vaInitialize failed: unknown libva error`** on startup is a harmless
  GPU/VA-API warning; the app falls back to software rendering and works fine.
- **Command not found in a shell**: ensure `~/.local/bin` is in your `PATH`.
- **No menu entry**: confirm `~/.local/share/applications/command-code.desktop`
  exists and is valid with `desktop-file-validate ~/.local/share/applications/command-code.desktop`.

## Files here

- `install-command-code.sh` — the idempotent installer (install / update / uninstall).
- `README.md` — this document.
