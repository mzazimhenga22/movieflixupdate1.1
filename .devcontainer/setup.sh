#!/usr/bin/env bash
set -e

# Versions
FLUTTER_VERSION=3.24.3
ANDROID_SDK_VERSION=11076708
ANDROID_PLATFORM=android-36
ANDROID_BUILD_TOOLS=36.0.0
ANDROID_NDK_VERSION=27.0.12077973

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

# Install Android SDK cmdline-tools
if [ ! -d "/usr/local/android-sdk" ]; then
  echo "Installing Android SDK..."
  mkdir -p /usr/local/android-sdk/cmdline-tools
  curl -o sdk-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip
  unzip sdk-tools.zip -d /usr/local/android-sdk/cmdline-tools
  mv /usr/local/android-sdk/cmdline-tools/cmdline-tools /usr/local/android-sdk/cmdline-tools/latest
  rm sdk-tools.zip
fi

# Set ANDROID env vars
echo 'export ANDROID_HOME=/usr/local/android-sdk' >> ~/.bashrc
echo 'export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH' >> ~/.bashrc
export ANDROID_HOME=/usr/local/android-sdk
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH

# Accept licenses
yes | sdkmanager --licenses

# Install SDK components
sdkmanager "platform-tools" \
           "platforms;${ANDROID_PLATFORM}" \
           "build-tools;${ANDROID_BUILD_TOOLS}" \
           "ndk;${ANDROID_NDK_VERSION}" \
           "cmake;3.22.1"

# Precache Flutter (includes Android engine artifacts)
flutter precache
flutter doctor -v

echo "✅ Setup complete. Run 'flutter doctor' to verify."
