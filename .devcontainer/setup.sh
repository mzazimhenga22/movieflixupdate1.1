#!/usr/bin/env bash
# Setup script for devcontainer: installs Android SDK, Flutter precache, etc.
# This script is intended to be run as the 'vscode' user in postCreateCommand.

set -euo pipefail

# Provide a sensible default for ANDROID_HOME if not set
: "${ANDROID_HOME:=/usr/local/android-sdk}"
export ANDROID_HOME
export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}"

# Versions (adjust if needed)
FLUTTER_VERSION=3.24.3
ANDROID_SDK_VERSION=11076708
ANDROID_PLATFORM=android-36
ANDROID_BUILD_TOOLS=36.0.0
ANDROID_NDK_VERSION=27.0.12077973

echo "➡️ ANDROID_HOME = ${ANDROID_HOME}"
echo "➡️ PATH = ${PATH}"

# Helper: run commands as current user (should be vscode). If script runs as root, prefer keeping files owned by vscode.
CURRENT_USER="${SUDO_USER:-$(whoami)}"
echo "➡️ Running as user: ${CURRENT_USER}"

# Install Flutter (only if not already installed)
if [ ! -d "/usr/local/flutter" ]; then
  echo "▶️ Installing Flutter ${FLUTTER_VERSION}..."
  curl -fsSL -o /tmp/flutter.tar.xz "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  tar -xf /tmp/flutter.tar.xz -C /tmp
  sudo mv /tmp/flutter /usr/local/flutter
  rm -f /tmp/flutter.tar.xz
fi

# Ensure flutter is on PATH for this script run
export PATH="/usr/local/flutter/bin:${PATH}"

# Install Android SDK commandline tools if missing
if [ ! -d "${ANDROID_HOME}/cmdline-tools/latest" ]; then
  echo "▶️ Installing Android SDK commandline-tools..."
  sudo mkdir -p "${ANDROID_HOME}/cmdline-tools"
  curl -fsSL -o /tmp/sdk-tools.zip "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip"
  sudo unzip -q /tmp/sdk-tools.zip -d "${ANDROID_HOME}/cmdline-tools"
  sudo mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"
  rm -f /tmp/sdk-tools.zip
fi

# Set JAVA_HOME for local commands
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export PATH="${JAVA_HOME}/bin:${PATH}"

# Accept licenses (non-interactive). If this fails, print diagnostics but continue so the devcontainer doesn't hard-fail.
if command -v sdkmanager >/dev/null 2>&1; then
  echo "▶️ Running sdkmanager --licenses (this may take a moment)..."
  # Pipe yes and tolerate non-zero if interactive acceptance isn't needed
  yes | sdkmanager --licenses || true
else
  echo "⚠️ sdkmanager not found in PATH. Skipping license acceptance step for now."
fi

# Install SDK components (only what's missing)
if command -v sdkmanager >/dev/null 2>&1; then
  echo "▶️ Installing required Android SDK components..."
  sdkmanager "platform-tools" \
            "platforms;${ANDROID_PLATFORM}" \
            "build-tools;${ANDROID_BUILD_TOOLS}" \
            "system-images;${ANDROID_PLATFORM};google_apis;x86_64" \
            "emulator" \
            "ndk;${ANDROID_NDK_VERSION}" \
            "cmake;3.22.1" || {
    echo "⚠️ Some sdkmanager installs failed. Check networking or SDK versions and re-run manually."
  }
else
  echo "⚠️ sdkmanager not available; skipping SDK components install."
fi

# Create an AVD if not already present (force recreate)
if command -v avdmanager >/dev/null 2>&1; then
  echo "▶️ Creating AVD 'codespaces_emulator' (force)..."
  echo "no" | avdmanager create avd -n codespaces_emulator -k "system-images;${ANDROID_PLATFORM};google_apis;x86_64" --force || {
    echo "⚠️ avdmanager create failed or AVD already exists."
  }
else
  echo "⚠️ avdmanager not found; skipping AVD creation."
fi

# Precache Flutter artifacts (if flutter present)
if command -v flutter >/dev/null 2>&1; then
  echo "▶️ Running flutter precache and doctor -v..."
  flutter precache || true
  flutter doctor -v || true
else
  echo "⚠️ flutter not found on PATH; skipping flutter precache."
fi

echo "✅ setup.sh finished."
echo "👉 To start emulator: bash .devcontainer/start-emulator.sh (or from your postCreateCommand)"

