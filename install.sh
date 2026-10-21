#!/bin/zsh
# Build mac-unlock and (re)start it as a LaunchAgent in this login session.
# On first run it also asks for your login password and creates the token.
set -euo pipefail
cd "${0:A:h}"

label=com.github.yehia-khalil.mac-unlock
plist=~/Library/LaunchAgents/$label.plist

mkdir -p bin
swiftc -O -o bin/mac-unlock main.swift

# Looking up the item's attributes (no -w) reads no secret, so it prompts for nothing.
if ! security find-generic-password -s mac-unlock -a token >/dev/null 2>&1; then
  bin/mac-unlock setup
fi

cat > $plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$PWD/bin/mac-unlock</string><string>serve</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/mac-unlock.log</string>
</dict>
</plist>
EOF

launchctl bootout gui/$UID/$label 2>/dev/null || true
launchctl bootstrap gui/$UID $plist
echo "Running. Log: ~/Library/Logs/mac-unlock.log"
