cat > ~/cleanup_flutter_space.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "This script will remove build caches and free space for Flutter/Android builds."
read -p "Proceed? (y/N): " yn
if [[ "${yn,,}" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

echo -e "\n1) flutter clean (project build dirs)"
# run in repo root if possible
if command -v flutter >/dev/null 2>&1; then
  flutter clean || true
else
  echo "flutter not found in PATH; skipping 'flutter clean'"
fi

echo -e "\n2) remove Android build folders in repo (android/.gradle, android/build)"
if [ -d android ]; then
  rm -rf android/.gradle android/app/build android/build || true
  echo "Removed android/.gradle and build directories."
else
  echo "No android/ folder in current repo; skipping."
fi

echo -e "\n3) remove Gradle cache (~/.gradle/caches) -- re-downloads may be required later"
if [ -d "$HOME/.gradle/caches" ]; then
  read -p "Delete ~/.gradle/caches (may re-download many MBs)? (y/N): " yn2
  if [[ "${yn2,,}" == "y" ]]; then
    rm -rf "$HOME/.gradle/caches"
    echo "Deleted ~/.gradle/caches"
  else
    echo "Skipped ~/.gradle/caches"
  fi
fi

echo -e "\n4) remove Android SDK temp/obsolete files (sdkmanager cache & extras)"
# safe best-effort deletions
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
if [ -d "$ANDROID_SDK_ROOT" ]; then
  rm -rf "$ANDROID_SDK_ROOT/.android" || true
  rm -rf "$ANDROID_SDK_ROOT/build-tools/*/temp" || true
  echo "Cleaned some Android SDK temp files (best-effort)"
else
  echo "No Android SDK found at $ANDROID_SDK_ROOT; skipping."
fi

echo -e "\n5) remove Flutter pub cache (hosted packages) — big if many packages"
if [ -d "$HOME/.pub-cache" ]; then
  read -p "Run 'flutter pub cache repair' instead of full wipe? (recommended) (Y/n): " yn3
  if [[ "${yn3,,}" == "n" ]]; then
    read -p "Delete ~/.pub-cache entirely? (y/N): " yn4
    if [[ "${yn4,,}" == "y" ]]; then
      rm -rf "$HOME/.pub-cache"
      echo "Deleted ~/.pub-cache"
    else
      echo "Skipped deleting ~/.pub-cache"
    fi
  else
    if command -v flutter >/dev/null 2>&1; then
      flutter pub cache repair || true
      echo "Ran pub cache repair"
    else
      echo "flutter not found; skipping pub cache repair"
    fi
  fi
fi

echo -e "\n6) delete node_modules (if present) — these can be huge"
if [ -d node_modules ]; then
  read -p "Delete ./node_modules? (y/N): " yn5
  if [[ "${yn5,,}" == "y" ]]; then
    rm -rf node_modules
    echo "Deleted node_modules"
  else
    echo "Skipped node_modules"
  fi
fi

echo -e "\n7) clean apt / package caches (if you have sudo)"
if command -v sudo >/dev/null 2>&1; then
  read -p "Run sudo apt-get clean && sudo apt-get autoremove -y? (requires sudo) (y/N): " yn6
  if [[ "${yn6,,}" == "y" ]]; then
    sudo apt-get clean
    sudo apt-get autoremove -y
    echo "Cleaned apt caches"
  else
    echo "Skipped apt-clean"
  fi
fi

echo -e "\n8) clear system journal logs (if using systemd) — can free GBs"
read -p "Vacuum journal logs older than 2 days? (requires sudo) (y/N): " yn7
if [[ "${yn7,,}" == "y" ]]; then
  if command -v sudo >/dev/null 2>&1 && command -v journalctl >/dev/null 2>&1; then
    sudo journalctl --vacuum-time=2d || true
    echo "Journal vacuumed"
  else
    echo "journalctl or sudo not available; skipping"
  fi
fi

echo -e "\n9) free ephemeral/temp folder (/ephemeral) — BE CAREFUL"
if [ -d /ephemeral ]; then
  read -p "Delete everything in /ephemeral? (THIS WILL REMOVE ALL FILES IN /ephemeral) (y/N): " yn8
  if [[ "${yn8,,}" == "y" ]]; then
    sudo rm -rf /ephemeral/* || true
    echo "Cleared /ephemeral/"
  else
    echo "Skipped clearing /ephemeral"
  fi
fi

echo -e "\n10) locate biggest remaining files in home (top 20)"
du -ah "$HOME" 2>/dev/null | sort -rh | head -n 20 || true

echo -e "\nDONE. Run 'df -h' to re-check disk usage."
EOF

chmod +x ~/cleanup_flutter_space.sh
echo "Created ~/cleanup_flutter_space.sh. Run it with:"
echo "  bash ~/cleanup_flutter_space.sh"
