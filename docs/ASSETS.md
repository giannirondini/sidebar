# Assets

Two image assets ship with the app, both in `Resources/`.

```
Resources/
├── AppIcon.png            # App icon, 1024×1024 PNG (also shown in README.md)
├── dmg-background.png     # DMG window background (optional)
└── screenshots/           # README screenshots
```

## App icon

`Resources/AppIcon.png` is the only source. `Bundler.toml` points at it (`icon = 'Resources/AppIcon.png'`) and swift-bundler generates `AppIcon.icns` with every size from 16 to 1024 px at build time (`Contents/Resources/AppIcon.icns`, `CFBundleIconFile` = `AppIcon`). No `.icns` is kept in the repo.

To change the icon, replace the PNG with another **1024×1024** PNG (RGBA, sRGB) and rebuild:

```bash
sips -g pixelWidth -g pixelHeight Resources/AppIcon.png   # must be 1024 × 1024
./scripts/clean.sh && ./scripts/build.sh
```

The icon is original to SidebArc. It must stay clearly distinct from Arc's icon (trademark) because it ships in public releases.

If Finder or the Dock keeps showing an old icon after a rebuild, clear the icon cache: `sudo rm -rf /Library/Caches/com.apple.iconservices.store && killall Dock Finder`.

## DMG background

`scripts/create-dmg.sh` copies `Resources/dmg-background.png` into the DMG's hidden `.background/` folder and sets it as the Finder window's background. Without the file the DMG is created with a plain window.

The layout is set in `create-dmg.sh`:

| Property | Value |
|---|---|
| Window | 600 × 400 pt (`bounds {100, 100, 700, 500}`) |
| Icon size | 180 px, text 14 pt |
| `SidebArc.app` | centre at (160, 200) |
| `Applications` link | centre at (460, 200) |

Size the image to the window (600 × 400); the current file is a plain 699 × 484 image. Keep the two icon areas clear.

To check it: `./scripts/build.sh --dmg`, then open `.build/dmg/SidebArc-<version>.dmg`. Setting the background needs Finder automation; if it fails the script prints a warning and the DMG still works.
