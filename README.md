# Ekran

A native macOS menu bar app for managing displays: flexible HiDPI scaling, DDC/CI brightness, XDR brightness, virtual screens, presets and automation. Written in Swift/AppKit with a thin Objective-C layer for system APIs. No dependencies.

> The app's interface is in Russian.

[![build](https://github.com/BOGOMOLOV-ARSENIQ/Ekran/actions/workflows/build.yml/badge.svg)](https://github.com/BOGOMOLOV-ARSENIQ/Ekran/actions/workflows/build.yml)

## Features

**Scaling and resolutions**
- Flexible HiDPI scaling for any monitor: 8–24 "looks like …" sizes in ~2.5% steps, from crisp 2× to more screen real estate, with a slider and a custom size.
- Every display mode, including the hidden ones: HiDPI, notch-free modes on MacBooks, refresh rates, favourites.
- Virtual screens of any size (HiDPI, 24–144 Hz) with auto-start.

**Brightness and image**
- Brightness: the built-in screen and Apple displays through DisplayServices, external monitors over DDC/CI, everything else through software dimming.
- Combined brightness: software dimming kicks in below the hardware minimum.
- Over DDC: contrast, volume, mute, input selection (HDMI/DP/USB-C), standby.
- XDR brightness above 100% on XDR MacBook Pros and HDR monitors, up to 2×.
- Image adjustment through the gamma table (no GPU cost): dimming, contrast, gamma, colour temperature, RGB, inversion.
- HDR toggle for HDR monitors, colour profile selection.
- Brightness sync between external monitors and the built-in screen (event driven, no polling).

**Keyboard**
- The Mac's brightness and volume keys control the external monitor under the cursor (⌥⇧ for a fine step). Before the first press after a pause, Ekran re-reads the monitor's real brightness, so changes made with the monitor's own buttons are taken into account.
- Global hotkeys for 13 actions.
- Its own on-screen indicator (OSD), drawn with Liquid Glass on macOS 26.

**Displays and arrangement**
- Disconnect and reconnect a display in software, without unplugging the cable, plus a "keep disconnected" option.
- Protection of arrangement and resolutions against macOS resets, a visual arrangement editor, "make main".
- "Keep full refresh rate" (per display, off by default): for video that stutters on an external monitor until the cursor moves. A 1-point invisible window is redrawn on every vsync so the compositor keeps updating at the display's full rate.
- Picture in picture: stream a display (a virtual one, for example) or a single window into a floating window.
- Display information with EDID decoding (HDR, YCbCr, modes) and export to `.bin`.

**Automation**
- Presets: save and apply scaling, resolution, brightness, profile and HDR for every display.
- `ekran://` URL scheme, an `ekranctl` CLI, a local HTTP API, and scripts on monitor connect and disconnect.

## What's missing

| BetterDisplay Pro feature | Why it isn't here |
|---|---|
| HDMI-CEC | macOS gives no access to CEC without special adapters; there is nothing to test against |
| Controlling TVs and receivers over the network | Every vendor has its own protocol; without the devices this is untestable code |
| Full-screen 3D LUT | Requires capturing and redrawing the whole screen, a constant GPU cost. 1D correction through gamma is available |
| EDID override | A mistake can leave a monitor unusable; only reading and exporting are implemented |
| Native mode for any size | BetterDisplay's mechanism is closed. Ekran uses a native mode when macOS offers one and falls back to a virtual display otherwise |
| 8/10-bit and RGB/YCbCr switching | No public way to do it on Apple Silicon |

## Requirements

- macOS 13 Ventura or newer.
- Apple Silicon (M1–M5) — fully supported. On Intel Macs DDC goes through a different mechanism that has not been verified on real hardware.
- Building needs only the Command Line Tools (`xcode-select --install`); Xcode is not required.

## Build and install

```bash
./build.sh --universal
```

The finished app lands in `build/Ekran.app` (a universal arm64 + x86_64 binary).

- `--install` — copy it into /Applications.
- `--debug` — debug build.

On first launch:
- **Quit BetterDisplay and similar utilities** (MonitorControl, Lunar). They fight over the same gamma tables and virtual displays. Ekran warns about them in its menu.
- The brightness and volume keys ask for the Accessibility permission for **Ekran Keys**, a small helper inside the app. It is granted once and survives rebuilds of Ekran (see below).
- Picture in picture asks for the Screen Recording permission.
- Launch at login: Settings → General (best run from /Applications).

The build is ad-hoc signed, and macOS ties permissions to the exact signature hash.
- **The main app** changes its hash on every rebuild, so Screen Recording (for picture in picture) may have to be granted again.
- **The key tap** lives in a separate helper, `Contents/Helpers/Ekran Keys.app`. `build.sh` builds it once and caches it in `build/cache`; the build is deterministic, so even a from-scratch build produces the same hash. The permission for the keys is kept.
- **If the helper's own code changes** (`Sources/KeyTap/main.m`), the permission has to be granted again. Ekran's menu then shows a "brightness keys need permission" item.

## How scaling works

The method depends on the size you pick.

**"Native"** (marked that way in the menu). macOS itself offers a HiDPI mode of that size and Ekran simply switches to it. The display's hardware pipeline does the scaling: no virtual display, no added latency, and the hardware cursor, full refresh rate and HDR are preserved.

**Every other size** goes through a hidden virtual display:
1. A virtual display with a set of "looks like W×H" sizes is created for the monitor.
2. Each size is rendered into a 2W×2H framebuffer, as on a Retina screen.
3. The physical monitor mirrors that display: the GPU scales the picture down to the panel's native resolution, and text stays crisp at any scale.
4. Changing the size is just a mode change on the virtual display, with nothing recreated.

Mirroring specifics:
- Slight latency and extra GPU load while redrawing. Idle costs nothing.
- Each activation costs 2–3 display reconfigurations. macOS waits for every app to respond to each one, so a short hitch is possible.
- While scaling is on, the monitor runs in SDR (HDR is unavailable) and protected video (DRM) may refuse to play.
- On a built-in screen with a notch the menu bar can slide under the cutout; the "Resolution" item is a better fit there.
- Every configuration change is scoped to the process: if Ekran quits or crashes, the monitor returns to its original state.
- macOS sometimes resets neighbouring screens' resolutions when the set of displays changes. Ekran remembers their modes and restores them.
- While all screens are asleep, macOS defers any configuration change. Ekran changes nothing during that time and applies everything on wake, otherwise the main thread would hang for 10 seconds.

## Automation

The `display` selector accepts `main`, `all`, `builtin`, `external`, `mouse`, a display ID, or part of a name. The full command list is `ekranctl help`.

URL scheme (for Shortcuts, Raycast, Alfred, Stream Deck):

```bash
open -g "ekran://brightness?display=external&value=70"
open -g "ekran://scale?display=external&width=1920"
open -g "ekran://preset?name=Работа"
```

CLI:

```bash
sudo ln -sf /Applications/Ekran.app/Contents/Resources/ekranctl /usr/local/bin/ekranctl
ekranctl list
ekranctl volume display=mouse delta=-10
ekranctl scale display=external step=1
ekranctl input display=external source=hdmi1
```

Brightness, contrast, volume and mute also take `osd=1` to show the on-screen indicator, and `get` takes `refresh=1` to re-read the monitor's values over DDC.

HTTP API (enabled in settings, listens on 127.0.0.1 only, token optional):

```bash
curl "http://127.0.0.1:55777/get?display=main"
curl -H "Authorization: Bearer <token>" "http://127.0.0.1:55777/brightness?display=all&value=40"
```

Scripts for monitor connect and disconnect are set in Settings → Displays. They get `$EKRAN_DISPLAY_NAME`, `$EKRAN_DISPLAY_ID`, `$EKRAN_DISPLAY_KEY` and `$EKRAN_EVENT`.

## What has been verified

On a MacBook Pro M3 Pro (macOS 26.6.2, built-in XDR screen) with a real Xiaomi Mi 34″ monitor (3440×1440, 180 Hz, HDMI):
- **Scaling:** switching between native mode and mirroring in both directions.
- **DDC:** reading and writing brightness, contrast and volume, each write confirmed by reading the value back from the monitor.
- **Keys:** the helper receives the Accessibility permission and installs the tap; the path "key press → Ekran → monitor brightness" works, and brightness keys change the external monitor rather than the built-in screen.
- **Display settings survive a reboot.** Monitors without a serial number (such as this Mi monitor) are keyed by UUID rather than by port number.

With a virtual test monitor (27″ 2560×1440):
- **Scaling:** enabling, changing size on the fly, custom size, HiDPI toggle, disabling, restoring after a restart, clean exit on SIGTERM. The monitor's place in the arrangement is preserved. Commands answer in under 0.1 s.
- **Virtual screens:** creation, HiDPI mode selection, removal.
- **Displays:** disconnect and reconnect, protection of neighbouring displays' modes, behaviour with a sleeping screen.
- **Automation:** HTTP API (token, port change), CLI, presets.
- **Data parsing:** EDID and size ladders for 9 typical resolutions.

Not verified on real hardware (needs system permissions or a visual check):
- Intel Macs;
- the HDR toggle for an external monitor;
- picture in picture;
- the hotkey recorder;
- how visible the XDR boost is.

If something misbehaves, send the output of:

```bash
log stream --level info --predicate 'subsystem == "app.ekran.Ekran"'
```

## Reset and uninstall

```bash
defaults delete app.ekran.Ekran
rm -rf /Applications/Ekran.app
```

## Project layout

```
Sources/CPrivate/        Objective-C: virtual displays, DDC (Apple Silicon/Intel), SkyLight, DisplayServices, glass view
Sources/Ekran/App/       entry point and module coordination
Sources/Ekran/Core/      display model, modes, settings, EDID
Sources/Ekran/Features/  scaling, brightness/DDC, gamma, XDR, virtual screens, OSD, automation…
Sources/Ekran/UI/        menu, settings, arrangement editor, info window
Sources/KeyTap/          the "Ekran Keys" helper: the media key tap and nothing else
build.sh                 build without Xcode
```

## License

MIT — see [LICENSE](LICENSE).
