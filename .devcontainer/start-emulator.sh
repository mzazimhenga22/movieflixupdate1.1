#!/usr/bin/env bash
# Start a headless Android emulator + lightweight desktop (Xvfb + fluxbox) and noVNC
set -eu

# Provide defaults if not set
: "${ANDROID_HOME:=/usr/local/android-sdk}"
export ANDROID_HOME
export PATH="${ANDROID_HOME}/emulator:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/cmdline-tools/latest/bin:${PATH}"
export DISPLAY=:0

# Helper to run background commands safely
run_bg() {
  local cmd="$*"
  nohup bash -c "$cmd" >/tmp/emulator_start.log 2>&1 &
  sleep 0.2
}

# Start virtual display if not running
if ! pgrep -x "Xvfb" >/dev/null 2>&1; then
  echo "▶️ Starting Xvfb..."
  run_bg "Xvfb :0 -screen 0 1280x800x16"
fi

# Start fluxbox if not running
if ! pgrep -x "fluxbox" >/dev/null 2>&1; then
  echo "▶️ Starting fluxbox..."
  run_bg "fluxbox"
fi

# Start emulator (headless). Ensure emulator binary exists.
EMULATOR_BIN="${ANDROID_HOME}/emulator/emulator"
if [ ! -x "${EMULATOR_BIN}" ]; then
  echo "❌ Emulator binary not found at ${EMULATOR_BIN}. Make sure Android SDK 'emulator' is installed."
  exit 1
fi

echo "▶️ Launching Android emulator (codespaces_emulator)..."
# Start without window; send to background
nohup "${EMULATOR_BIN}" -avd codespaces_emulator -no-snapshot -noaudio -no-boot-anim -gpu swiftshader_indirect -no-window >/tmp/android_emulator.log 2>&1 &

# Wait for device up (with timeout)
echo "⏳ Waiting for emulator to boot (timeout 300s)..."
ADB_BIN="${ANDROID_HOME}/platform-tools/adb"
if ! command -v "${ADB_BIN}" >/dev/null 2>&1; then
  echo "⚠️ adb not found on PATH; attempting to use platform-tools adb"
fi

# wait-for-device loop with timeout
timeout=300
interval=2
elapsed=0
while true; do
  if "${ADB_BIN}" wait-for-device 2>/dev/null; then
    # check for boot completion
    BOOT_COMPLETE=$("${ADB_BIN}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    if [ "${BOOT_COMPLETE}" = "1" ]; then
      echo "✅ Emulator booted."
      break
    fi
  fi

  if [ "$elapsed" -ge "$timeout" ]; then
    echo "⚠️ Timeout waiting for emulator to boot (waited ${timeout}s). Check /tmp/android_emulator.log for details."
    break
  fi

  sleep "${interval}"
  elapsed=$((elapsed + interval))
done

# Start x11vnc if not running
if ! pgrep -x "x11vnc" >/dev/null 2>&1; then
  echo "▶️ Starting x11vnc..."
  run_bg "x11vnc -display :0 -nopw -forever -rfbport 5900"
fi

# Start noVNC/websockify if not running
if ! pgrep -f "websockify.*6080" >/dev/null 2>&1; then
  if [ -d "/usr/share/novnc" ]; then
    echo "▶️ Starting noVNC (websockify) on port 6080..."
    run_bg "websockify --web=/usr/share/novnc/ 6080 localhost:5900"
  else
    echo "⚠️ noVNC web files not found at /usr/share/novnc. Install novnc or adjust path."
  fi
fi

echo "✅ Emulator start script finished. Open Codespaces forwarded port 6080 to preview the desktop (noVNC)."

