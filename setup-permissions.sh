#!/bin/bash
# VibeFader — Grant Audio Capture permission
# The macOS Audio Tap API requires kTCCServiceAudioCapture, which is separate
# from the Screen & System Audio Recording toggle in System Settings.
# This script grants that permission to VibeFader.

set -e

BUNDLE_ID="com.chadon.VibeFader"
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

echo "Granting Audio Capture permission to $BUNDLE_ID..."

sqlite3 "$TCC_DB" \
  "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags) \
   VALUES ('kTCCServiceAudioCapture', '$BUNDLE_ID', 0, 2, 3, 1, 0);"

echo "Done! Also make sure VibeFader has 'Screen & System Audio Recording' enabled in:"
echo "  System Settings → Privacy & Security → Screen & System Audio Recording"
echo ""
echo "You may need to restart VibeFader for the change to take effect."
