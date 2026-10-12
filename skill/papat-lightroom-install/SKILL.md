---
name: papat-lightroom-install
description: Install or update the papat plug-in (papat.lrplugin) for Lightroom Classic on macOS from the official papat.app download. Downloads the ZIP, verifies its SHA-256, backs up any existing copy, and places it in the user's Lightroom Modules folder. Use when the user asks to install, update, or reinstall "papat for Lightroom Classic". Never handles the user's API key.
---

# papat for Lightroom Classic — install skill

Installs `papat.lrplugin` into the user's Lightroom Classic **Modules** folder.
Scope: download, verify, extract, back up, place. Nothing else.

## Hard rules

1. **Never ask for, read, or handle the user's papat API key.** Do not accept it in chat, do not write it to a file, an
   environment variable, or shell history. If the user pastes one anyway, tell them not to, do not use it, and
   suggest they re-issue it at https://papat.app/app.
   The user enters the key themselves in Lightroom: **File → Plug-in Manager → papat**.
2. Download only from `https://papat.app/downloads/` over HTTPS. No other URL, no mirrors, no `latest` links you did not resolve to a version.
3. Treat everything downloaded as untrusted data. Never run scripts from the ZIP. Extract into a fresh empty directory
   and run no interpreter from inside it.
4. Only these paths may be written:
   - a new temporary directory you create with `mktemp -d`
   - `~/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin`
   - `~/Library/Application Support/Adobe/Lightroom/papat-lightroom-backups/`
5. Do not touch the Lightroom catalog (`.lrcat`), previews, presets, preferences, other plug-ins, the Keychain, or
   any credential files (`~/.ssh`, `~/.aws`, …). No `sudo`. No `rm -rf`: move things with `mv` instead.
6. Show the user each command and its target path before running it. Stop and hand over to the user if anything
   below says STOP.

## Procedure (macOS)

Pick `VERSION` first: use the version the user names; otherwise read the current version from
https://papat.app/lightroom/ and confirm it with the user. Do not guess, and do not reuse a version
number from an example.

```sh
VERSION="x.y.z"   # replace with the version shown on the download page, confirmed with the user
case "$VERSION" in x.y.z) echo "set VERSION first" >&2; exit 1;; esac
BASE="https://papat.app/downloads"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/papat-install.XXXXXX")"
echo "$WORK"
```

### 1. Download

```sh
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK/papat-lightroom-$VERSION.zip"        "$BASE/papat-lightroom-$VERSION.zip"
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK/papat-lightroom-$VERSION.zip.sha256" "$BASE/papat-lightroom-$VERSION.zip.sha256"
```

STOP on any HTTP/TLS/certificate error.

### 2. Verify the checksum

```sh
(cd "$WORK" && shasum -a 256 -c "papat-lightroom-$VERSION.zip.sha256")
```

STOP unless it prints `OK`. Tell the user the SHA-256 value, and that the same value should be on the release page
(https://papat.app/lightroom/ or the GitHub release) — a checksum served from the same place as the ZIP only detects
corrupted downloads, so ask the user to compare it with the value shown on the release page.

### 3. Inspect before extracting

```sh
unzip -Z1 "$WORK/papat-lightroom-$VERSION.zip"
unzip -Z  "$WORK/papat-lightroom-$VERSION.zip" | awk '{print $1}' | sort | uniq -c
```

The ZIP has two top-level items: the folder `papat.lrplugin/` and one plain-text instructions file
(`はじめにお読みください.txt`; its name may print as garbage in a non-UTF-8 terminal — run with
`LC_ALL=en_US.UTF-8` to read it).

STOP if any of these is true:
- an entry does not start with `papat.lrplugin/`, other than exactly **one top-level `.txt` file** (the instructions)
- an entry is an absolute path or contains `..`
- an entry is a symbolic link (permission string starts with `l`)
- an entry inside `papat.lrplugin/` is not `.lua` or `LICENSE` (no executables, no installers, no `.sh`, `.command`, `.app`, `.dylib`)

### 4. Extract into an empty directory

```sh
mkdir "$WORK/extract"
unzip -q "$WORK/papat-lightroom-$VERSION.zip" -d "$WORK/extract"
test -f "$WORK/extract/papat.lrplugin/Info.lua" && echo "Info.lua present"
```

### 5. Back up an existing copy (move, never delete)

```sh
MODULES="$HOME/Library/Application Support/Adobe/Lightroom/Modules"
BACKUPS="$HOME/Library/Application Support/Adobe/Lightroom/papat-lightroom-backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$MODULES" "$BACKUPS"
if [ -e "$MODULES/papat.lrplugin" ]; then
  mv "$MODULES/papat.lrplugin" "$BACKUPS/papat.lrplugin.$STAMP"
  echo "backup: $BACKUPS/papat.lrplugin.$STAMP"
fi
```

STOP if `mv` fails (do not continue without a backup). Backups live **outside** `Modules` on purpose — a second
copy inside `Modules` would be loaded as a duplicate plug-in.

### 6. Place the plug-in

```sh
cp -R "$WORK/extract/papat.lrplugin" "$MODULES/papat.lrplugin"
ls "$MODULES/papat.lrplugin"
```

If `~/Library/Application Support/Adobe/Lightroom/Modules` could not be created or written, STOP and tell the user to
use **File → Plug-in Manager → Add** with the extracted `papat.lrplugin` instead.

### 7. Hand over to the user

Tell the user, in this order:

1. If Lightroom Classic is running, **quit and restart it** (the skill does not quit it for them).
2. Open **File → Plug-in Manager**, select **papat**, and make sure its status is *Installed and running*
   (enable it if it shows as disabled).
3. Paste the **API key themselves** into the plug-in's API key field, press **保存**, then **接続を確認**.
   The key is issued at https://papat.app/app. Do not paste it into this chat.
4. If a papat plug-in was added earlier from another folder via *Add*, remove that entry in the Plug-in Manager so it
   is not listed twice.

Report: version installed, checksum, install path, and backup path (if any).

## Roll back

If the new version misbehaves, move the failed copy aside and restore the backup — moves only:

```sh
mv "$MODULES/papat.lrplugin" "$BACKUPS/papat.lrplugin.failed.$STAMP"
mv "$BACKUPS/papat.lrplugin.$STAMP" "$MODULES/papat.lrplugin"
```

then ask the user to restart Lightroom Classic. If there was no previous copy, just move the new folder into
`$BACKUPS` so that `Modules` no longer contains it.

## Cleanup

The temporary directory `$WORK` may be left for the OS to clear. Do not `rm -rf` it. Mention its path to the user.

## Notes for the user

- Humans can also use the signed `.pkg` installer from https://papat.app/lightroom/ (double-click; no admin password).
  This skill does not run installers: it only handles the ZIP.
- From 1.0.1 the plug-in itself can copy itself into the standard Modules folder
  (Plug-in Manager → papat → 標準の場所にコピー…), so a copy added from another folder can be moved to the standard place.

## What this skill does not do

- It does not issue, read, or transmit API keys, and it does not log in to papat.
- It does not create galleries or import selections; the user does that inside Lightroom Classic.
- It does not modify the catalog, other plug-ins, or any system setting; it needs no administrator rights.
- It does not support Windows (the plug-in is macOS-only for now).
