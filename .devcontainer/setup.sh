#!/usr/bin/env bash
set -e

# Versions
FLUTTER_VERSION=3.24.3
ANDROID_SDK_VERSION=10406996
ANDROID_NDK_VERSION=26.1.10909125

# Install Flutter
if [ ! -d "/usr/local/flutter" ]; then
  echo "Installing Flutter..."
  curl -o flutter.tar.xz https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz
  tar xf flutter.tar.xz
  sudo mv flutter /usr/local/flutter
  rm flutter.tar.xz
fi

# Add Flutter to PATH
echo 'export PATH=/usr/local/flutter/bin:$PATH' >> ~/.bashrc
export PATH=/usr/local/flutter/bin:$PATH

# Install Android SDK commandline tools
if [ ! -d "/usr/local/android-sdk" ]; then
  echo "Installing Android SDK..."
  mkdir -p /usr/local/android-sdk/cmdline-tools
  curl -o sdk-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip
  unzip sdk-tools.zip -d /usr/local/android-sdk/cmdline-tools
  mv /usr/local/android-sdk/cmdline-tools/cmdline-tools /usr/local/android-sdk/cmdline-tools/latest
  rm sdk-tools.zip
fi

# Set Android env vars
echo 'export ANDROID_HOME=/usr/local/android-sdk' >> ~/.bashrc
echo 'export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH' >> ~/.bashrc
export ANDROID_HOME=/usr/local/android-sdk
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH

# Accept licenses
yes | sdkmanager --licenses

# Install required SDK packages
sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" "ndk;$ANDROID_NDK_VERSION" "cmake;3.22.1"

# Precache Flutter artifacts
flutter precache
flutter doctor -v

echo "✅ Setup complete. Run 'flutter doctor' to verify."
