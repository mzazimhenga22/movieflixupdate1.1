#!/usr/bin/env bash
set -e

# Ensure ANDROID_HOME is set
if [ -z "$ANDROID_HOME" ]; then
  echo "❌ ANDROID_HOME is not set. Add it in devcontainer.json or setup.sh"
  exit 1
fi

# Start virtual display (only if not already running)
if ! pgrep -x "Xvfb" > /dev/null; then
  echo "▶️ Starting Xvfb..."
  Xvfb :0 -screen 0 1280x800x16 &
fi
export DISPLAY=:0

# Start fluxbox (only if not already running)
if ! pgrep -x "fluxbox" > /dev/null; then
  echo "▶️ Starting fluxbox..."
  fluxbox > /dev/null 2>&1 &
fi

# Start the emulator headless
echo "▶️ Launching Android emulator..."
$ANDROID_HOME/emulator/emulator -avd codespaces_emulator \
  -no-snapshot -noaudio -no-boot-anim \
  -gpu swiftshader_indirect -no-window &

# Wait for device
echo "⏳ Waiting for emulator to boot..."
$ANDROID_HOME/platform-tools/adb wait-for-device
$ANDROID_HOME/platform-tools/adb shell input keyevent 82

# Start VNC + noVNC (only if not already running)
if ! pgrep -x "x11vnc" > /dev/null; then
  echo "▶️ Starting x11vnc..."
  x11vnc -display :0 -nopw -forever -rfbport 5900 > /dev/null 2>&1 &
fi

if ! pgrep -f "websockify.*6080" > /dev/null; then
  echo "▶️ Starting noVNC (websockify)..."
  websockify --web=/usr/share/novnc/ 6080 localhost:5900 > /dev/null 2>&1 &
fi

echo "✅ Emulator running. Open Codespaces port 6080 → Preview in browser to see it."
