# standalone-emu

Run an Android emulator on an Apple Silicon Mac **without Android Studio and without Java**.

It downloads only the pieces you need (adb, the emulator and one system image straight from Google), writes the virtual device config by hand, and gives you a small `standalone-emu` command. Handy when disk space is tight, or when the JVM-based `sdkmanager` / `avdmanager` tools crash on your machine (e.g. macOS betas).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Mandrusian/standalone-emu/main/install.sh | bash
```

Read [`install.sh`](install.sh) first if you like; piping to bash deserves a look.

Needs about 6 GB free. Everything lands in `~/Library/Android/sdk` and `~/.android/avd`.

## Use

```sh
standalone-emu start                 # boot in the background, wait until ready
standalone-emu install app.apk       # install once; apps persist between runs
standalone-emu install app.xapk      # also handles .xapk / .apkm / .apks bundles
standalone-emu status                # devices + user-installed apps
standalone-emu stop                  # clean shutdown (protects your data)
standalone-emu shell                 # adb shell
standalone-emu uninstall --sdk       # remove everything
```

Apps and data live in the AVD and survive restarts. They are only lost if you start with `-wipe-data` or delete the AVD.

## Options

Set these before running the installer, e.g. `API_LEVEL=34 IMAGE_TYPE=google_apis curl ... | bash`.

| Variable | Default | Meaning |
|---|---|---|
| `API_LEVEL` | `35` | Android API level |
| `IMAGE_TYPE` | `default` | `default` (smallest), `google_apis`, or `google_apis_playstore` |
| `AVD_NAME` | `android` | Virtual device name |
| `DATA_SIZE` | `4G` | Data partition size |
| `RAM_MB` | `2048` | Guest RAM |
| `ANDROID_HOME` | `~/Library/Android/sdk` | Install location |
| `BIN_DIR` | `~/.local/bin` | Where the CLI goes |
| `FORCE` | unset | `1` skips the disk-space check |

At runtime: `EMU_GPU` (default `host`; try `swiftshader_indirect` or `guest` for graphics glitches) and `EMU_SNAPSHOT=1` for fast-boot snapshots (costs 1 to 2 GB).

## Notes

- Apple Silicon only. The image is arm64.
- The `default` image has no Google Play Services. Apps that need Google login or Play Services need `IMAGE_TYPE=google_apis` (or `google_apis_playstore`).
- Some apps refuse to run on emulators.
- Split bundles (`.apkm`, `.xapk`) are installed best-effort; bundles containing splits for several architectures or densities can fail to install.
- Downloads come directly from `dl.google.com`; the script does not verify checksums.

## License

MIT
