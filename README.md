# medal-patcher

Patcher for Medal. Blocks ads and telemetry

## Run it

```powershell
irm https://raw.githubusercontent.com/jaasonw/medal-patcher/main/medal-patcher.ps1 | iex
```

Or locally if downloaded (PowerShell blocks unsigned script files by default):

```powershell
powershell -ExecutionPolicy Bypass -File .\medal-patcher.ps1
```

## Menu

| | |
|---|---|
| **1** | Apply patch (waits for you to close Medal, then patches and relaunches) |
| **2** | Restore original `app.asar` (also waits for Medal to be closed) |
| **3** | Toggle removing ads (blocks ad traffic, stops the ad webviews attaching, hides the empty slots) |
| **4** | Toggle blocking telemetry (Amplitude, Sentry, Honeycomb, Mixpanel, GA, DoubleClick) |
| **5** | Edit `%APPDATA%\Medal\user.css` - injected into every Medal window |
| **6** | Show the patch log (`%TEMP%\medal-patcher.log`) |

Toggles are saved to `%LOCALAPPDATA%\medal-patcher\config.json` and restored on
the next run. A changed toggle takes effect the next time you apply the patch.

## How it works

Medal ships Electron with the `EnableEmbeddedAsarIntegrityValidation` and
`OnlyLoadAppFromAsar` fuses **disabled** (readable in the fuse wire inside
`Medal.exe`), so its entry point can be replaced.

Dropping a `resources\app\` folder beside `app.asar` — normally the first path
Electron searches — does **not** work on this build; Electron ignores it. So the
patcher instead:

1. Backs up `resources\app.asar` to `app.asar.bak`.
2. Extracts the real entry point to `app.asar.unpacked\index-orig.js`.
3. Writes a shim to `app.asar.unpacked\index.js`.
4. Rewrites the top-level `index.js` entry in the asar header from
   `{"size":N,"offset":"..."}` to `{"size":N,"unpacked":true,"pad":"xxx..."}`,
   **padded to the exact same byte length**. Because the header's byte length is
   unchanged, every other file's offset in the 40 MB archive stays valid and the
   archive never has to be repacked.

Electron then loads the shim as the app entry point. The shim:

- cancels every request in the `persist:ads` session — Medal renders each ad in
  a `<webview partition="persist:ads">`, so this kills all of them at once;
- injects `div[data-fallback-reason]{display:none!important}` into every window
  (that attribute marks the root of every ad slot in Medal's renderer), plus a
  debounced `MutationObserver` that climbs to the slot's card wrapper and hides
  it, so no empty placeholder is left in the clip grid;
- cancels analytics requests (Amplitude, Sentry, Honeycomb, Mixpanel, GA,
  DoubleClick) on the default session and every session created later;
- injects `%APPDATA%\Medal\user.css` into every window, if that file exists;
- then runs `index-orig.js` through `module._compile` with this file's own
  `__filename`, so `__dirname` stays inside the asar and all of Medal's relative
  requires resolve exactly as before.

## Notes

- **Patch needs to be reapplied every update** Medal's updater replaces `current\`, so re-run the patcher
  after an app update.s
- Revert any time with menu option 2, or manually:
  `copy /Y "%LOCALAPPDATA%\Medal\current\resources\app.asar.bak" "%LOCALAPPDATA%\Medal\current\resources\app.asar"`

## License

[MIT](LICENSE)
