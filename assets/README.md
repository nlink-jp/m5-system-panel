# assets

**`AppIcon-1024.png`** (1024×1024 PNG) is the companion's app icon: the panel
showing its overview page, in the colours the firmware draws. It is drawn by
`swift scripts/gen-icon.swift`; change the script and regenerate rather than
editing the image.

`make build-app` runs `scripts/make-icns.sh` to turn it into `AppIcon.icns` in the
`.app` bundle's Resources. The icon is required: the build fails without it.
