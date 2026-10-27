#!/usr/bin/env bash
# standalone-emu: Android emulator on Apple Silicon without Android Studio or Java.
# https://github.com/Mandrusian/standalone-emu
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<user>/standalone-emu/main/install.sh | bash
#
# Options (environment variables):
#   API_LEVEL    Android API level            (default: 35)
#   IMAGE_TYPE   default | google_apis | google_apis_playstore   (default: default)
#   AVD_NAME     name of the virtual device   (default: android)
#   DATA_SIZE    data partition size          (default: 4G)
#   RAM_MB       guest RAM in MB              (default: 2048)
#   ANDROID_HOME where to put the SDK pieces  (default: ~/Library/Android/sdk)
#   BIN_DIR      where to put the CLI         (default: ~/.local/bin)
#   FORCE=1      skip the free-disk-space check
set -euo pipefail

API_LEVEL="${API_LEVEL:-35}"
IMAGE_TYPE="${IMAGE_TYPE:-default}"
AVD_NAME="${AVD_NAME:-android}"
DATA_SIZE="${DATA_SIZE:-4G}"
RAM_MB="${RAM_MB:-2048}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
REPO_URL="https://dl.google.com/android/repository"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- checks -----------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] \
  || die "This installer supports Apple Silicon Macs only."
for t in curl unzip awk; do
  command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
done

case "$IMAGE_TYPE" in
  default)               REPO_DIR=android;                TAG_DISPLAY="Default Android System Image"; PLAYSTORE=false ;;
  google_apis)           REPO_DIR=google_apis;            TAG_DISPLAY="Google APIs";                  PLAYSTORE=false ;;
  google_apis_playstore) REPO_DIR=google_apis_playstore;  TAG_DISPLAY="Google Play";                  PLAYSTORE=true  ;;
  *) die "IMAGE_TYPE must be default, google_apis or google_apis_playstore" ;;
esac

mkdir -p "$SDK"
avail_kb="$(df -k "$SDK" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 6000000 ] && [ "${FORCE:-0}" != "1" ]; then
  die "Only $((avail_kb / 1024 / 1024)) GB free; need about 6 GB. Re-run with FORCE=1 to override."
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fL --progress-bar -o "$2" "$1"; }
latest() { # latest <xml-url> <regex>  -> highest matching filename
  curl -fsSL "$1" | grep -oE "$2" | sort -V -u | tail -n1 || true
}

# ---- platform-tools (adb) ---------------------------------------------------
if [ -x "$SDK/platform-tools/adb" ]; then
  log "platform-tools already present, skipping"
else
  log "Downloading platform-tools (adb)"
  fetch "$REPO_URL/platform-tools-latest-darwin.zip" "$TMP/pt.zip"
  unzip -q "$TMP/pt.zip" -d "$SDK"
fi

# ---- emulator ---------------------------------------------------------------
if [ -x "$SDK/emulator/emulator" ]; then
  log "emulator already present, skipping"
else
  EMU_ZIP="$(latest "$REPO_URL/repository2-3.xml" 'emulator-darwin_aarch64-[0-9]+\.zip')"
  [ -n "$EMU_ZIP" ] || die "Could not find the emulator download in Google's manifest."
  log "Downloading emulator ($EMU_ZIP)"
  fetch "$REPO_URL/$EMU_ZIP" "$TMP/emu.zip"
  unzip -q "$TMP/emu.zip" -d "$SDK"
fi

# ---- system image -----------------------------------------------------------
IMG_REL="system-images/android-$API_LEVEL/$IMAGE_TYPE/arm64-v8a"
if [ -f "$SDK/$IMG_REL/system.img" ]; then
  log "System image already present, skipping"
else
  IMG_ZIP="$(latest "$REPO_URL/sys-img/$REPO_DIR/sys-img2-3.xml" "arm64-v8a-${API_LEVEL}_r[0-9]+\.zip")"
  [ -n "$IMG_ZIP" ] || die "No arm64 '$IMAGE_TYPE' image found for API $API_LEVEL. Try another API_LEVEL or IMAGE_TYPE."
  log "Downloading system image ($IMG_ZIP), this is the big one"
  fetch "$REPO_URL/sys-img/$REPO_DIR/$IMG_ZIP" "$TMP/img.zip"
  mkdir -p "$TMP/img"
  unzip -q "$TMP/img.zip" -d "$TMP/img"
  found="$(find "$TMP/img" -name system.img -print -quit)"
  [ -n "$found" ] || die "system.img not found inside the downloaded image."
  mkdir -p "$SDK/$(dirname "$IMG_REL")"
  rm -rf "$SDK/$IMG_REL"
  mv "$(dirname "$found")" "$SDK/$IMG_REL"
fi

# ---- AVD (hand-written, so no Java / avdmanager needed) ---------------------
if [ -d "$AVD_HOME/$AVD_NAME.avd" ]; then
  log "AVD '$AVD_NAME' already exists, leaving it untouched"
else
  log "Creating AVD '$AVD_NAME'"
  mkdir -p "$AVD_HOME/$AVD_NAME.avd"
  cat > "$AVD_HOME/$AVD_NAME.ini" <<EOF
avd.ini.encoding=UTF-8
path=$AVD_HOME/$AVD_NAME.avd
target=android-$API_LEVEL
EOF
  cat > "$AVD_HOME/$AVD_NAME.avd/config.ini" <<EOF
AvdId=$AVD_NAME
avd.ini.displayname=$AVD_NAME
PlayStore.enabled=$PLAYSTORE
abi.type=arm64-v8a
hw.cpu.arch=arm64
hw.cpu.ncore=4
hw.ramSize=$RAM_MB
hw.gpu.enabled=yes
hw.gpu.mode=auto
hw.lcd.width=1080
hw.lcd.height=2400
hw.lcd.density=420
hw.keyboard=yes
hw.audioInput=yes
hw.audioOutput=yes
hw.camera.back=none
hw.camera.front=none
disk.dataPartition.size=$DATA_SIZE
image.sysdir.1=$IMG_REL/
tag.id=$IMAGE_TYPE
tag.display=$TAG_DISPLAY
showDeviceFrame=no
fastboot.forceColdBoot=no
EOF
fi

# ---- CLI wrapper ------------------------------------------------------------
log "Installing CLI to $BIN_DIR/standalone-emu"
mkdir -p "$BIN_DIR"
sed -e "s|__SDK__|$SDK|g" -e "s|__AVD__|$AVD_NAME|g" \
    -e "s|__AVDHOME__|$AVD_HOME|g" -e "s|__IMGREL__|$IMG_REL|g" \
    > "$BIN_DIR/standalone-emu" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

SDK="__SDK__"
AVD="__AVD__"
AVD_HOME="__AVDHOME__"
IMG_REL="__IMGREL__"
ADB="$SDK/platform-tools/adb"
EMU="$SDK/emulator/emulator"
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
standalone-emu: Android emulator without Android Studio

  start [emulator flags]   boot the emulator in the background and wait for it
  stop                     shut it down cleanly (protects your data)
  status                   show running devices and installed user apps
  install <file...>        install an .apk, several split .apks, or an .xapk/.apkm/.apks bundle
  shell [cmd]              adb shell
  adb <args>               run adb directly
  uninstall [--sdk]        remove the AVD and this CLI; --sdk also removes the emulator,
                           platform-tools and the system image

Environment: EMU_GPU (default host; try swiftshader_indirect or guest if graphics glitch),
             EMU_SNAPSHOT=1 (enable fast-boot snapshots, costs 1-2 GB)
USAGE
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift

case "$cmd" in
  start)
    if "$ADB" devices 2>/dev/null | grep -q '^emulator-'; then
      echo "Emulator already running."; exit 0
    fi
    flags=(-avd "$AVD" -gpu "${EMU_GPU:-host}")
    [ "${EMU_SNAPSHOT:-0}" = "1" ] || flags+=(-no-snapshot-save)
    nohup "$EMU" "${flags[@]}" "$@" >/tmp/standalone-emu.log 2>&1 &
    echo "Starting '$AVD' (log: /tmp/standalone-emu.log)"
    "$ADB" wait-for-device
    until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
    echo "Booted."
    ;;
  stop)
    "$ADB" emu kill
    ;;
  status)
    "$ADB" devices -l
    echo "--- user-installed apps ---"
    "$ADB" shell pm list packages -3 2>/dev/null | sed 's/^package://' || true
    ;;
  install)
    [ $# -ge 1 ] || die "usage: standalone-emu install <file.apk | splits... | bundle.xapk>"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    apks=(); bundle=0
    for f in "$@"; do
      [ -f "$f" ] || die "not a file: $f"
      case "$f" in
        *.xapk|*.apkm|*.apks)
          bundle=1
          d="$tmp/$(basename "$f")"; mkdir -p "$d"; unzip -q "$f" -d "$d"
          while IFS= read -r a; do apks+=("$a"); done < <(find "$d" -name '*.apk' | sort)
          ;;
        *) apks+=("$f") ;;
      esac
    done
    [ ${#apks[@]} -gt 0 ] || die "no .apk files found"
    if [ ${#apks[@]} -eq 1 ] && [ "$bundle" -eq 0 ]; then
      "$ADB" install -r "${apks[0]}"
    else
      "$ADB" install-multiple -r "${apks[@]}"
    fi
    ;;
  shell) exec "$ADB" shell "$@" ;;
  adb)   exec "$ADB" "$@" ;;
  uninstall)
    "$ADB" emu kill >/dev/null 2>&1 || true
    printf 'Delete AVD "%s"%s and this CLI? [y/N] ' "$AVD" "$([ "${1:-}" = "--sdk" ] && echo ", emulator, platform-tools and system image")"
    read -r ans </dev/tty
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Cancelled."; exit 1; }
    rm -rf "$AVD_HOME/$AVD.avd" "$AVD_HOME/$AVD.ini"
    if [ "${1:-}" = "--sdk" ]; then
      rm -rf "$SDK/emulator" "$SDK/platform-tools" "$SDK/$IMG_REL"
    fi
    rm -f "$0"
    echo "Removed."
    ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
WRAPPER
chmod +x "$BIN_DIR/standalone-emu"

# ---- done -------------------------------------------------------------------
log "Done."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo
     echo "Add the CLI to your PATH:"
     echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac
cat <<EOF

Next:
  standalone-emu start
  standalone-emu install ~/Downloads/app.apk
EOF
