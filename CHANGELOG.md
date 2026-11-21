# Changelog

## 1.0.1 — renamed to FluidPlay

- The app is now called **FluidPlay** (bundle ID `io.github.pkozubski.fluidplay`), with a new icon.
- On first launch, settings, the measured frame-generation cost, recently played games, session snapshots
  and paired consoles are carried over from VeyraMac — no need to link the console again.
- Session logs are now written to `~/Library/Logs/FluidPlay`.
- Environment variables for the scripts are now `FLUIDPLAY_*` (e.g. `FLUIDPLAY_RELEASE_IDENTITY`).

## 1.0.0 — first public release (as VeyraMac)

### Remote Play
- Built-in PS5 Remote Play over the local network (chiaki-ng): pairing with the console's PIN, waking
  from rest mode, H.264/HEVC at 1080p/720p/540p, bitrate up to 100 Mbps.
- Full DualSense support: haptics and vibration (adjustable strength), adaptive triggers, light bar,
  touchpad, gyro and accelerometer. Trigger values are re-sent after changes so a lost packet can't
  leave the console with a stale brake/throttle value.
- PS, Create, Options and touchpad buttons and a volume control in the in-game bar.

### Frame generation
- Apple's ML frame interpolation (`VTLowLatencyFrameInterpolation`) resamples the game onto the
  display's refresh grid: every refresh gets a frame from the right moment, for 24, 30 and 40 fps games.
- Duplicate-frame detection for 30 fps games in a 60 fps stream; phase-locked estimate of when the game
  rendered each frame.
- Per-frame cost measurement with automatic fallback when the Mac is too slow for the game's frame rate.
- The model is warmed up in the background before frame generation starts.
- Late frames move the display timeline back by one refresh (and it returns after 10 s without late
  frames) instead of stuttering.

### Image
- MetalFX upscaling with contrast-adaptive sharpening; ML super resolution for streams up to 720p.

### Interface
- Console-style home screen with an animated background, console cards with a snapshot of the last game,
  and recently played games.
- Full-screen connecting screen (cancel with Esc or SHARE + OPTIONS).
- In-game bar on a progressive blur that hides together with the cursor.
- English and Polish localization.

### Diagnostics
- Per-second session log that attributes hitches to the network, the Mac or the game.
- Headless self-tests (`--selftest`, `--discover`, `--motion-test`, `--decode-test`, `--ui-test`).

### Distribution
- `Scripts/release.sh` builds a self-contained DMG for macOS 26+ on Apple silicon (static third-party
  libraries, hardened runtime, optional Developer ID signing and notarization).
