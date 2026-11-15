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

`scripts/create-dmg.sh` passes `Resources/dmg-background.png` to Homebrew's `create-dmg` (`--background`), which sets it as the Finder window's background. Without the file the DMG gets a plain window.

The layout is set in `create-dmg.sh`:

| Property | Value |
|---|---|
| Window | 600 × 400 pt (`--window-size 600 400`) |
| Icon size | 180 px, text 14 pt |
| `SidebArc.app` | centre at (160, 200) |
| `Applications` link | centre at (460, 200) |

The image must be **600 × 400 points**, which is pixels × 72 / DPI: Finder draws it at that size from the top-left corner. So either 600 × 400 px at 72 DPI, or 1200 × 800 px at 144 DPI (sharper on Retina). Image editors often save 300 DPI, which shrinks a 600 × 400 image to 144 × 96 points; `create-dmg.sh` refuses that and prints the `sips` command that fixes it (`sips -s dpiWidth 72 -s dpiHeight 72 Resources/dmg-background.png`). Keep the two icon areas clear.

To check it: `./scripts/create-dmg.sh` (after `./scripts/build.sh`), then open `.build/release/<version>/SidebArc-<version>.dmg`. Setting the layout and background needs Finder automation for the terminal. Without it create-dmg fails (exit 64, no DMG); `create-dmg.sh` then retries without the styling and warns, so you get a working DMG with the default layout.
