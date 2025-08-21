#!/usr/bin/env bash
set -e

# Start Xvfb (virtual display)
Xvfb :0 -screen 0 1280x800x16 &
export DISPLAY=:0

# Start window manager (fluxbox)
fluxbox &

# Launch emulator from $ANDROID_HOME
$ANDROID_HOME/emulator/emulator -avd codespaces_emulator \
    -no-snapshot -noaudio -no-boot-anim \
    -gpu swiftshader_indirect -no-window &

# Give emulator some time to boot
echo "⏳ Waiting for emulator to boot..."
$ANDROID_HOME/platform-tools/adb wait-for-device
$ANDROID_HOME/platform-tools/adb shell input keyevent 82

# Start VNC + noVNC server
x11vnc -display :0 -nopw -forever -rfbport 5900 &
websockify --web=/usr/share/novnc/ 6080 localhost:5900 &

echo "✅ Emulator running. Open forwarded port 6080 in Codespaces to see it."
