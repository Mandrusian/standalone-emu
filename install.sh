#!/usr/bin/env bash
# standalone-emu: Android emulator on Apple Silicon without Android Studio or Java.
# https://github.com/Mandrusian/standalone-emu
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Mandrusian/standalone-emu/main/install.sh | bash
#
# Options (environment variables):
#   API_LEVEL         Android API level                              (default: 35)
#   IMAGE_TYPE        default | google_apis | google_apis_playstore  (default: default)
#   AVD_NAME          name of the virtual device                     (default: android)
#   DATA_SIZE         data partition size                            (default: 4G)
#   RAM_MB            guest RAM in MB                                (default: 2048)
#   ANDROID_HOME      where to put the SDK pieces                    (default: ~/Library/Android/sdk)
#   ANDROID_AVD_HOME  where to put AVD data                          (default: ~/.android/avd)
#   BIN_DIR           where to put the CLI                           (default: ~/.local/bin)
#   FORCE=1           skip the free-disk-space check
set -euo pipefail

API_LEVEL="${API_LEVEL:-35}"
IMAGE_TYPE="${IMAGE_TYPE:-default}"
AVD_NAME="${AVD_NAME:-android}"
DATA_SIZE="${DATA_SIZE:-4G}"
RAM_MB="${RAM_MB:-2048}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
REPO_URL="${REPO_URL:-https://dl.google.com/android/repository}"

[ "$SDK" != "/" ] && SDK="${SDK%/}"
[ "$BIN_DIR" != "/" ] && BIN_DIR="${BIN_DIR%/}"
[ "$AVD_HOME" != "/" ] && AVD_HOME="${AVD_HOME%/}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- checks -----------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  die "This installer supports Apple Silicon Macs only."
fi
for t in curl unzip awk grep sort find sed tr; do
  command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
done

case "$API_LEVEL" in
  ''|*[!0-9]*) die "API_LEVEL must be a positive integer (got: $API_LEVEL)" ;;
esac
[ "$API_LEVEL" -gt 0 ] || die "API_LEVEL must be a positive integer (got: $API_LEVEL)"

case "$RAM_MB" in
  ''|*[!0-9]*) die "RAM_MB must be a positive integer (got: $RAM_MB)" ;;
esac
[ "$RAM_MB" -gt 0 ] || die "RAM_MB must be a positive integer (got: $RAM_MB)"

[[ "$DATA_SIZE" =~ ^[1-9][0-9]*[KMGTPkmgtp]?$ ]] \
  || die "DATA_SIZE must be a size like 4G or 4096M (got: $DATA_SIZE)"

[[ "$AVD_NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "AVD_NAME must contain only letters, digits, '.', '_' or '-' (got: $AVD_NAME)"

case "$IMAGE_TYPE" in
  default)               REPO_DIR=android;                TAG_DISPLAY="Default Android System Image"; PLAYSTORE=false ;;
  google_apis)           REPO_DIR=google_apis;            TAG_DISPLAY="Google APIs";                  PLAYSTORE=false ;;
  google_apis_playstore) REPO_DIR=google_apis_playstore;  TAG_DISPLAY="Google Play";                  PLAYSTORE=true  ;;
  *) die "IMAGE_TYPE must be default, google_apis or google_apis_playstore" ;;
esac

IMG_REL="system-images/android-$API_LEVEL/$IMAGE_TYPE/arm64-v8a"

mkdir -p "$SDK"
need_pt=0; need_emu=0; need_img=0
[ -x "$SDK/platform-tools/adb" ] || need_pt=1
[ -x "$SDK/emulator/emulator" ] || need_emu=1
[ -f "$SDK/$IMG_REL/system.img" ] || need_img=1

req_kb=0
if [ "$need_img" -eq 1 ]; then
  req_kb=6000000
elif [ "$need_pt" -eq 1 ] || [ "$need_emu" -eq 1 ]; then
  req_kb=1000000
fi

if [ "$req_kb" -gt 0 ] && [ "${FORCE:-0}" != "1" ]; then
  avail_kb="$(df -kP "$SDK" | awk 'NR==2{print $4}')"
  case "$avail_kb" in
    ''|*[!0-9]*) avail_kb=0 ;;
  esac
  if [ "$avail_kb" -lt "$req_kb" ]; then
    need_gb=$(( (req_kb + 999999) / 1000000 ))
    die "Only $((avail_kb / 1024 / 1024)) GB free; need about ${need_gb} GB. Re-run with FORCE=1 to override."
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fL --progress-bar -o "$2" "$1"; }
latest() { # latest <xml-url> <regex> -> highest matching filename
  local xml
  xml="$(curl -fsSL "$1")" || return 1
  printf '%s\n' "$xml" | grep -oE "$2" | sort -V -u | tail -n1 || true
}

# ---- platform-tools (adb) ---------------------------------------------------
if [ "$need_pt" -eq 0 ]; then
  log "platform-tools already present, skipping"
else
  log "Downloading platform-tools (adb)"
  fetch "$REPO_URL/platform-tools-latest-darwin.zip" "$TMP/pt.zip"
  mkdir -p "$TMP/pt"
  unzip -oq "$TMP/pt.zip" -d "$TMP/pt"
  [ -x "$TMP/pt/platform-tools/adb" ] || die "adb not found inside platform-tools archive."
  rm -rf "$SDK/platform-tools"
  mv "$TMP/pt/platform-tools" "$SDK/platform-tools"
fi

# ---- emulator ---------------------------------------------------------------
if [ "$need_emu" -eq 0 ]; then
  log "emulator already present, skipping"
else
  EMU_ZIP="$(latest "$REPO_URL/repository2-3.xml" 'emulator-darwin_aarch64-[0-9]+\.zip')" \
    || die "Failed to fetch Google's emulator manifest."
  [ -n "$EMU_ZIP" ] || die "Could not find the emulator download in Google's manifest."
  log "Downloading emulator ($EMU_ZIP)"
  fetch "$REPO_URL/$EMU_ZIP" "$TMP/emu.zip"
  mkdir -p "$TMP/emu"
  unzip -oq "$TMP/emu.zip" -d "$TMP/emu"
  [ -x "$TMP/emu/emulator/emulator" ] || die "emulator binary not found inside archive."
  rm -rf "$SDK/emulator"
  mv "$TMP/emu/emulator" "$SDK/emulator"
fi

# ---- system image -----------------------------------------------------------
if [ "$need_img" -eq 0 ]; then
  log "System image already present, skipping"
else
  IMG_ZIP="$(latest "$REPO_URL/sys-img/$REPO_DIR/sys-img2-3.xml" "arm64-v8a-${API_LEVEL}_r[0-9]+\.zip")" \
    || die "Failed to fetch Google's system image manifest."
  [ -n "$IMG_ZIP" ] || die "No arm64 '$IMAGE_TYPE' image found for API $API_LEVEL. Try another API_LEVEL or IMAGE_TYPE."
  log "Downloading system image ($IMG_ZIP), this is the big one"
  fetch "$REPO_URL/sys-img/$REPO_DIR/$IMG_ZIP" "$TMP/img.zip"
  mkdir -p "$TMP/img"
  unzip -oq "$TMP/img.zip" -d "$TMP/img"
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
wrapper_tmp="$TMP/standalone-emu"
{
  cat <<'WRAPPER_HEAD'
#!/usr/bin/env bash
set -euo pipefail

WRAPPER_HEAD
  printf 'SDK=%q\nAVD=%q\nAVD_HOME=%q\nIMG_REL=%q\n' "$SDK" "$AVD_NAME" "$AVD_HOME" "$IMG_REL"
  cat <<'WRAPPER_BODY'
ADB="$SDK/platform-tools/adb"
EMU="$SDK/emulator/emulator"
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
standalone-emu: Android emulator without Android Studio

  start [emulator flags]      boot the emulator in the background and wait for it
  stop                        shut it down cleanly (protects your data)
  status                      show running devices and installed user apps
  install <file...>           install an .apk, several split .apks, or an .xapk/.apkm/.apks bundle
  shell [cmd]                 adb shell
  adb <args>                  run adb directly
  uninstall [--sdk] [-y]      remove the AVD and this CLI; --sdk also removes the emulator,
                              platform-tools and the system image (-y skips confirmation)

Environment: EMU_GPU (default host; try swiftshader_indirect or guest if graphics glitch),
             EMU_SNAPSHOT=1 (enable fast-boot snapshots, costs 1-2 GB),
             EMU_LOG (override emulator log path)
USAGE
}

cmd="${1:-help}"
if [ $# -gt 0 ]; then
  shift
fi

case "$cmd" in
  start)
    if "$ADB" devices 2>/dev/null | grep -q '^emulator-'; then
      echo "Emulator already running."; exit 0
    fi
    [ -x "$EMU" ] || die "Emulator binary not found at $EMU"
    [ -x "$ADB" ] || die "adb binary not found at $ADB"
    log_file="${EMU_LOG:-${TMPDIR:-/tmp}/standalone-emu-$AVD.log}"
    flags=(-avd "$AVD" -gpu "${EMU_GPU:-host}")
    if [ "${EMU_SNAPSHOT:-0}" != "1" ]; then
      flags+=(-no-snapshot-save)
    fi
    "$ADB" start-server >/dev/null 2>&1 || true
    nohup "$EMU" "${flags[@]}" "$@" </dev/null >"$log_file" 2>&1 &
    emu_pid=$!
    echo "Starting '$AVD' (log: $log_file)"
    while true; do
      if ! kill -0 "$emu_pid" 2>/dev/null; then
        tail -n 20 "$log_file" >&2 || true
        die "Emulator exited before booting (log: $log_file)"
      fi
      if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
        break
      fi
      sleep 2
    done
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
    apks=(); bundle=0; idx=0
    for f in "$@"; do
      [ -f "$f" ] || die "not a file: $f"
      case "$f" in
        *.xapk|*.apkm|*.apks|*.XAPK|*.APKM|*.APKS)
          bundle=1
          idx=$((idx + 1))
          d="$tmp/$idx"
          mkdir -p "$d"
          unzip -oq "$f" -d "$d"
          while IFS= read -r -d '' a; do
            apks+=("$a")
          done < <(find "$d" -type f -iname '*.apk' -print0 | LC_ALL=C sort -z)
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
    with_sdk=0
    yes_flag=0
    for arg in "$@"; do
      case "$arg" in
        --sdk)    with_sdk=1 ;;
        -y|--yes) yes_flag=1 ;;
        *) die "unknown option for uninstall: $arg (expected --sdk, -y|--yes)" ;;
      esac
    done
    if [ "$yes_flag" -ne 1 ]; then
      sdk_msg=""
      if [ "$with_sdk" -eq 1 ]; then
        sdk_msg=", emulator, platform-tools and system image"
      fi
      printf 'Delete AVD "%s"%s and this CLI? [y/N] ' "$AVD" "$sdk_msg"
      read -r ans || ans=""
      case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled."; exit 1 ;;
      esac
    fi
    "$ADB" emu kill >/dev/null 2>&1 || true
    rm -rf "$AVD_HOME/$AVD.avd" "$AVD_HOME/$AVD.ini"
    if [ "$with_sdk" -eq 1 ]; then
      rm -rf "$SDK/emulator" "$SDK/platform-tools" "$SDK/$IMG_REL"
      d="$IMG_REL"
      while [ "$d" != "." ] && [ "$d" != "/" ]; do
        d="$(dirname "$d")"
        [ "$d" = "." ] && break
        rmdir "$SDK/$d" 2>/dev/null || break
      done
    fi
    rm -f "$0"
    echo "Removed."
    ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
WRAPPER_BODY
} > "$wrapper_tmp"
chmod +x "$wrapper_tmp"
mv "$wrapper_tmp" "$BIN_DIR/standalone-emu"

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
