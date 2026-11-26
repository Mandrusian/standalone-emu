#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$msg"
  else
    fail "$msg (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  case "$haystack" in
    *"$needle"*) pass "$msg" ;;
    *) fail "$msg (missing '$needle' in output)" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  case "$haystack" in
    *"$needle"*) fail "$msg (unexpectedly found '$needle')" ;;
    *) pass "$msg" ;;
  esac
}

assert_check() {
  local msg="$1"
  shift
  if "$@"; then
    pass "$msg"
  else
    fail "$msg"
  fi
}

WORK="$(mktemp -d)"
cleanup() {
  if [ -f "$WORK/emu.pid" ]; then
    local pid
    pid="$(cat "$WORK/emu.pid" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 1. Syntax checks -------------------------------------------------------
bash -n "$INSTALLER"
pass "bash -n install.sh"

# ---- 2. Mock environment & fixtures -----------------------------------------
MOCK_BIN="$WORK/mock-bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "${MOCK_UNAME_S:-Darwin}" ;;
  -m) echo "${MOCK_UNAME_M:-arm64}" ;;
  *)  /usr/bin/uname "$@" ;;
esac
EOF
chmod +x "$MOCK_BIN/uname"

# Mock df that reports plenty of space unless MOCK_DF_KB is set
cat > "$MOCK_BIN/df" <<'EOF'
#!/usr/bin/env bash
if [ -n "${MOCK_DF_KB:-}" ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf '/dev/disk1 10000000 9000000 %s 90%% /\n' "$MOCK_DF_KB"
else
  /bin/df "$@"
fi
EOF
chmod +x "$MOCK_BIN/df"

# ---- 3. Validation & platform error handling --------------------------------
run_expect_fail() {
  local desc="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "$desc"
  else
    fail "$desc (expected non-zero exit, got 0; output: $out)"
  fi
}

run_expect_fail "reject non-Darwin OS" env PATH="$MOCK_BIN:$PATH" MOCK_UNAME_S=Linux bash "$INSTALLER"
run_expect_fail "reject non-arm64 arch" env PATH="$MOCK_BIN:$PATH" MOCK_UNAME_M=x86_64 bash "$INSTALLER"
run_expect_fail "reject invalid IMAGE_TYPE" env PATH="$MOCK_BIN:$PATH" IMAGE_TYPE=invalid bash "$INSTALLER"
run_expect_fail "reject non-numeric API_LEVEL" env PATH="$MOCK_BIN:$PATH" API_LEVEL=abc bash "$INSTALLER"
run_expect_fail "reject zero RAM_MB" env PATH="$MOCK_BIN:$PATH" RAM_MB=0 bash "$INSTALLER"
run_expect_fail "reject invalid DATA_SIZE" env PATH="$MOCK_BIN:$PATH" DATA_SIZE=0G bash "$INSTALLER"
run_expect_fail "reject unsafe AVD_NAME" env PATH="$MOCK_BIN:$PATH" AVD_NAME="../evil" bash "$INSTALLER"
run_expect_fail "reject low disk space without FORCE=1" \
  env PATH="$MOCK_BIN:$PATH" MOCK_DF_KB=1000000 ANDROID_HOME="$WORK/low-disk-sdk" bash "$INSTALLER"

# ---- 4. Build mock Google repository archives -------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/sys-img/google_apis_playstore" "$WORK/src/platform-tools" "$WORK/src/emulator" "$WORK/src/img/nested/arm64-v8a"

cat > "$WORK/src/platform-tools/adb" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE="$WORK/adb-state"
LOG="$WORK/adb-calls.log"
mkdir -p "\$STATE"
printf '%s\n' "\$*" >> "\$LOG"
case "\${1:-}" in
  start-server) exit 0 ;;
  devices)
    if [ -f "\$STATE/running" ]; then
      echo "List of devices attached"
      echo "emulator-5554	device"
    else
      echo "List of devices attached"
    fi
    ;;
  shell)
    shift
    case "\${1:-}" in
      getprop)
        if [ "\${2:-}" = "sys.boot_completed" ] && [ -f "\$STATE/booted" ]; then
          echo "1"
        else
          exit 1
        fi
        ;;
      pm)
        echo "package:com.example.app"
        ;;
      *) exit 0 ;;
    esac
    ;;
  emu)
    if [ "\${2:-}" = "kill" ]; then
      rm -f "\$STATE/running" "\$STATE/booted"
      if [ -f "$WORK/emu.pid" ]; then
        pid="\$(cat "$WORK/emu.pid" 2>/dev/null || true)"
        if [ -n "\$pid" ]; then
          kill "\$pid" 2>/dev/null || true
        fi
        rm -f "$WORK/emu.pid"
      fi
    fi
    ;;
  install|install-multiple)
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/src/platform-tools/adb"

cat > "$WORK/src/emulator/emulator" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE="$WORK/adb-state"
mkdir -p "\$STATE"
printf '%s\n' "\$*" > "$WORK/emu-args.log"
if [ "\${MOCK_EMU_CRASH:-0}" = "1" ]; then
  echo "fatal: simulated emulator crash" >&2
  exit 1
fi
echo "\$\$" > "$WORK/emu.pid"
touch "\$STATE/running"
touch "\$STATE/booted"
spid=""
trap 'if [ -n "\$spid" ]; then kill "\$spid" 2>/dev/null || true; fi; exit 0' TERM INT
sleep 30 &
spid=\$!
wait "\$spid"
EOF
chmod +x "$WORK/src/emulator/emulator"

printf 'fake-system-img' > "$WORK/src/img/nested/arm64-v8a/system.img"

(cd "$WORK/src" && zip -qr "$REPO/platform-tools-latest-darwin.zip" platform-tools)
(cd "$WORK/src" && zip -qr "$REPO/emulator-darwin_aarch64-16982698.zip" emulator)
(cd "$WORK/src/img" && zip -qr "$REPO/sys-img/google_apis_playstore/arm64-v8a-34_r10.zip" nested)

cat > "$REPO/repository2-3.xml" <<'EOF'
<sdk-repository>
  <remotePackage path="emulator">
    <archives>
      <archive><complete><url>emulator-darwin_aarch64-16970787.zip</url></complete></archive>
      <archive><complete><url>emulator-darwin_aarch64-16982698.zip</url></complete></archive>
    </archives>
  </remotePackage>
</sdk-repository>
EOF

cat > "$REPO/sys-img/google_apis_playstore/sys-img2-3.xml" <<'EOF'
<sdk-sys-img>
  <remotePackage path="system-images;android-34;google_apis_playstore;arm64-v8a">
    <archives>
      <archive><complete><url>arm64-v8a-34_r02.zip</url></complete></archive>
      <archive><complete><url>arm64-v8a-34_r10.zip</url></complete></archive>
    </archives>
  </remotePackage>
</sdk-sys-img>
EOF

# ---- 5. End-to-end install with special characters in paths -----------------
SDK_DIR="$WORK/sdk & special|dir"
BIN_DIR="$WORK/bin & dir"
AVD_DIR="$WORK/avd home"

PATH="$MOCK_BIN:$PATH" \
  REPO_URL="file://$REPO" \
  API_LEVEL=34 \
  IMAGE_TYPE=google_apis_playstore \
  AVD_NAME=Pixel_8 \
  DATA_SIZE=8G \
  RAM_MB=4096 \
  ANDROID_HOME="$SDK_DIR" \
  ANDROID_AVD_HOME="$AVD_DIR" \
  BIN_DIR="$BIN_DIR" \
  FORCE=1 \
  bash "$INSTALLER" >/dev/null

CLI="$BIN_DIR/standalone-emu"
assert_check "CLI wrapper installed and executable" test -x "$CLI"
bash -n "$CLI"
pass "bash -n generated CLI wrapper"

assert_check "adb installed" test -x "$SDK_DIR/platform-tools/adb"
assert_check "emulator installed" test -x "$SDK_DIR/emulator/emulator"
assert_check "system.img installed via sort -V r10 selection" \
  test -f "$SDK_DIR/system-images/android-34/google_apis_playstore/arm64-v8a/system.img"

config_ini="$AVD_DIR/Pixel_8.avd/config.ini"
assert_contains "$(cat "$config_ini")" "PlayStore.enabled=true" "config.ini PlayStore enabled"
assert_contains "$(cat "$config_ini")" "hw.ramSize=4096" "config.ini RAM_MB"
assert_contains "$(cat "$config_ini")" "disk.dataPartition.size=8G" "config.ini DATA_SIZE"
assert_contains "$(cat "$config_ini")" "image.sysdir.1=system-images/android-34/google_apis_playstore/arm64-v8a/" "config.ini sysdir"

# Idempotent re-run even with low disk space (since all components exist)
rerun_out="$(
  PATH="$MOCK_BIN:$PATH" \
  MOCK_DF_KB=100000 \
  REPO_URL="file://$REPO" \
  API_LEVEL=34 \
  IMAGE_TYPE=google_apis_playstore \
  AVD_NAME=Pixel_8 \
  ANDROID_HOME="$SDK_DIR" \
  ANDROID_AVD_HOME="$AVD_DIR" \
  BIN_DIR="$BIN_DIR" \
  bash "$INSTALLER" 2>&1
)"
assert_contains "$rerun_out" "already present, skipping" "idempotent rerun skips downloads"
assert_contains "$rerun_out" "leaving it untouched" "idempotent rerun preserves AVD"

# ---- 6. CLI wrapper functional tests ----------------------------------------
help_out="$("$CLI")"
assert_contains "$help_out" "standalone-emu: Android emulator" "no-arg prints help"
run_expect_fail "unknown subcommand fails" "$CLI" nope

# Crash fast test
crash_out=""
rc=0
crash_out="$(MOCK_EMU_CRASH=1 EMU_LOG="$WORK/crash.log" "$CLI" start 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && [[ "$crash_out" == *"Emulator exited before booting"* ]]; then
  pass "start fails fast when emulator crashes"
else
  fail "start did not fail fast on emulator crash (rc=$rc out=$crash_out)"
fi

# Normal start & already-running check
start_out="$(EMU_LOG="$WORK/emu.log" "$CLI" start 2>&1)"
assert_contains "$start_out" "Booted." "start boots emulator"
assert_contains "$(cat "$WORK/emu-args.log")" "-no-snapshot-save" "start passes -no-snapshot-save by default"

again_out="$("$CLI" start 2>&1)"
assert_eq "Emulator already running." "$again_out" "second start detects running emulator"

status_out="$("$CLI" status)"
assert_contains "$status_out" "emulator-5554" "status shows running emulator"
assert_contains "$status_out" "com.example.app" "status strips package: prefix"

# Stop, then start with EMU_SNAPSHOT=1
"$CLI" stop
assert_check "stop cleared running emulator" test ! -f "$WORK/adb-state/running"

EMU_SNAPSHOT=1 EMU_LOG="$WORK/emu.log" "$CLI" start >/dev/null 2>&1
assert_not_contains "$(cat "$WORK/emu-args.log")" "-no-snapshot-save" "EMU_SNAPSHOT=1 omits -no-snapshot-save"

# Install tests (single apk + colliding xapk basenames)
mkdir -p "$WORK/apks/dir1" "$WORK/apks/dir2" "$WORK/apks/bundle1" "$WORK/apks/bundle2" "$WORK/apks/empty"
printf 'apk0' > "$WORK/apks/single.apk"
printf 'apk1' > "$WORK/apks/bundle1/base.apk"
printf 'apk2' > "$WORK/apks/bundle2/split.apk"
(cd "$WORK/apks/bundle1" && zip -q "$WORK/apks/dir1/app.xapk" base.apk)
(cd "$WORK/apks/bundle2" && zip -q "$WORK/apks/dir2/app.xapk" split.apk)
printf 'not-an-apk' > "$WORK/apks/empty/readme.txt"
(cd "$WORK/apks/empty" && zip -q "$WORK/apks/empty.xapk" readme.txt)

: > "$WORK/adb-calls.log"
"$CLI" install "$WORK/apks/single.apk"
assert_contains "$(cat "$WORK/adb-calls.log")" "install -r" "single apk uses adb install -r"

: > "$WORK/adb-calls.log"
"$CLI" install "$WORK/apks/dir1/app.xapk" "$WORK/apks/dir2/app.xapk"
calls="$(cat "$WORK/adb-calls.log")"
assert_contains "$calls" "install-multiple -r" "bundles use adb install-multiple -r"
assert_contains "$calls" "base.apk" "first bundle apk extracted"
assert_contains "$calls" "split.apk" "second colliding-basename bundle apk extracted"

run_expect_fail "empty xapk rejected" "$CLI" install "$WORK/apks/empty.xapk"
run_expect_fail "missing file rejected" "$CLI" install "$WORK/apks/missing.apk"

# Uninstall cancel must NOT kill running emulator
cancel_rc=0
printf 'n\n' | "$CLI" uninstall >/dev/null 2>&1 || cancel_rc=$?
assert_check "uninstall cancel exits non-zero" test "$cancel_rc" -ne 0
assert_check "uninstall cancel did not kill running emulator" test -f "$WORK/adb-state/running"
assert_check "uninstall cancel preserved CLI" test -x "$CLI"

# Uninstall --sdk -y removes everything cleanly
"$CLI" uninstall --sdk -y >/dev/null
assert_check "uninstall -y removed CLI" test ! -e "$CLI"
assert_check "uninstall removed AVD" test ! -e "$AVD_DIR/Pixel_8.avd"
assert_check "uninstall --sdk removed emulator" test ! -e "$SDK_DIR/emulator"
assert_check "uninstall --sdk removed platform-tools" test ! -e "$SDK_DIR/platform-tools"
assert_check "uninstall --sdk removed system-images" test ! -e "$SDK_DIR/system-images"

echo
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
