# papat-fprint

The similarity helper bundled with the plug-in (`papat.lrplugin/bin/papat-fprint`, built fresh
by `scripts/build-pkg.sh`; never checked into the repository as a binary). macOS only. Based on
a spike that measured this approach (Vision feature prints, time groups refined where the
picture changes sharply) on a real 296-photo shoot before this version was commissioned.

Reads photo paths and the already-computed time groups (`lib/grouping.lua`, a Lua port of the
gallery's own `autoGroups`), asks Vision for an image feature print per photo
(`VNGenerateImageFeaturePrintRequest`, on-device, no networking — only Foundation and Vision
are imported, nothing that could make a request is ever called), and refines the time groups
where the picture changes sharply within one of them. Writes only 1-based group numbers; no
feature print, distance, or photo is written anywhere.

```sh
xcrun swiftc -O -o /tmp/papat-fprint main.swift      # one architecture, for a quick check
echo '{"photos":["/tmp/a.jpg","/tmp/b.jpg"],"timeGroups":[1,1]}' > /tmp/in.json
/tmp/papat-fprint /tmp/in.json /tmp/out.json && cat /tmp/out.json
```

`scripts/build-pkg.sh` builds a universal binary (arm64 + x86_64, whichever Mac runs it) and
signs it when `PAPAT_APP_IDENTITY` (a Developer ID Application certificate, distinct from the
installer's own `PAPAT_INSTALLER_IDENTITY`) is set — see `docs/guide-signing.md`.

The plug-in (`papat.lrplugin/lib/similarity.lua`) never treats a non-zero exit, a missing
binary, or an unreadable answer as an error to show anyone: it just sends the gallery without
similarity groups, the same as on Windows (the gallery falls back to time groups alone).
