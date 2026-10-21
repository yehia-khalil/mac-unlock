#!/bin/zsh
# Stop mac-unlock and remove its LaunchAgent and Keychain items.
set -u
label=com.github.yehia-khalil.mac-unlock

launchctl bootout gui/$UID/$label 2>/dev/null
rm -f ~/Library/LaunchAgents/$label.plist
security delete-generic-password -s mac-unlock -a token >/dev/null 2>&1
security delete-generic-password -s mac-unlock -a password >/dev/null 2>&1
echo "Removed. Turn mac-unlock off in System Settings → Privacy & Security → Accessibility."
