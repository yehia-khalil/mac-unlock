#!/bin/zsh
# Build a universal (Apple silicon + Intel) binary and pack it into dist/mac-unlock-<version>.dmg.
#   ./make-dmg.sh 0.1.0
set -euo pipefail
cd "${0:A:h}"

version=${1:?usage: ./make-dmg.sh <version>}
stage=dist/stage
rm -rf dist && mkdir -p $stage

for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 -o dist/mac-unlock-$arch main.swift
done
lipo -create -output $stage/mac-unlock dist/mac-unlock-arm64 dist/mac-unlock-x86_64

cp install.sh "$stage/Install mac-unlock.command"
cp uninstall.sh "$stage/Uninstall mac-unlock.command"
cp README.md LICENSE $stage/

hdiutil create -quiet -volname "mac-unlock $version" -srcfolder $stage -format UDZO -ov dist/mac-unlock-$version.dmg
rm -rf $stage dist/mac-unlock-arm64 dist/mac-unlock-x86_64
echo dist/mac-unlock-$version.dmg
