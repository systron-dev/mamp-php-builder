#!/bin/bash
# Build zlib from source into MAMP Library ($MAMP).
# MAMP ships zlib 1.2.11 (2017) which has known CVEs (CVE-2018-25032,
# CVE-2022-37434). This upgrades the dylib, static lib, and headers while
# keeping the install_name inside /Applications/MAMP/Library — no Homebrew,
# no MacPorts runtime dependency.
# Usage: bash build-zlib-mamp.sh [version]

set -e

VERSION="${1:-1.3.2}"
MAMP=/Applications/MAMP/Library
BUILD="/tmp/php-build-${USER:-mamp}/zlib-${VERSION}"
ARCH=$(uname -m)
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

# Known-good checksum for 1.3.2 (zlib.net)
case "$VERSION" in
  1.3.2) SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16" ;;
  1.3.1) SHA256="38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32" ;;
  *) SHA256="" ;;
esac

if [ ! -d "$BUILD" ]; then
  echo "==> Downloading zlib $VERSION..."
  mkdir -p "$(dirname "$BUILD")"
  curl -fsSL "https://zlib.net/zlib-${VERSION}.tar.gz" -o "/tmp/zlib-${VERSION}.tar.gz"
  if [ -n "$SHA256" ]; then
    echo "$SHA256  /tmp/zlib-${VERSION}.tar.gz" | shasum -a 256 -c -
  else
    echo "WARNING: no known checksum for $VERSION — verify manually"
  fi
  mkdir -p "$BUILD"
  tar xzf "/tmp/zlib-${VERSION}.tar.gz" -C "$BUILD" --strip-components=1
  rm -f "/tmp/zlib-${VERSION}.tar.gz"
fi

cd "$BUILD"
export CFLAGS="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export LDFLAGS="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
./configure --prefix="$MAMP"
make -j"$(sysctl -n hw.ncpu)"

# Back up MAMP's original 1.2.11 library and headers before overwriting
STAMP=$(date +%Y%m%d-%H%M%S)
for f in libz.1.2.11.dylib libz.1.dylib libz.dylib libz.a zlib.h zconf.h; do
  if [ -e "$MAMP/lib/$f" ] && [ ! -e "$MAMP/lib/$f.bak-$STAMP" ]; then
    cp -a "$MAMP/lib/$f" "$MAMP/lib/$f.bak-$STAMP"
  fi
  if [ -e "$MAMP/include/$f" ] && [ ! -e "$MAMP/include/$f.bak-$STAMP" ]; then
    cp -a "$MAMP/include/$f" "$MAMP/include/$f.bak-$STAMP"
  fi
done

echo "==> Installing zlib $VERSION into $MAMP..."
# Targeted install: MAMP's lib/pkgconfig is root-owned, and `make install`
# aborts there before copying headers. Install only what the build needs.
install -m 644 libz.a                    "$MAMP/lib/libz.a"
install -m 755 "libz.$VERSION.dylib"     "$MAMP/lib/libz.$VERSION.dylib"
ln -sfn "libz.$VERSION.dylib"            "$MAMP/lib/libz.1.dylib"
ln -sfn "libz.$VERSION.dylib"            "$MAMP/lib/libz.dylib"
ln -sfn "libz.$VERSION.dylib"            "$MAMP/lib/libz.1.$VERSION.dylib"
install -m 644 zlib.h zconf.h            "$MAMP/include/"
install -m 644 zlib.3                    "$MAMP/share/man/man3/"
# pkgconfig is optional; skip when the directory is not writable
if [ -w "$MAMP/lib/pkgconfig" ]; then
  install -m 644 zlib.pc "$MAMP/lib/pkgconfig/"
fi

# Ad-hoc sign the new dylib (arm64 requires a valid signature)
codesign --force --sign - "$MAMP/lib/libz.$VERSION.dylib" 2>/dev/null || true

echo "==> Verify:"
otool -D "$MAMP/lib/libz.1.dylib"
otool -l "$MAMP/lib/libz.1.dylib" | grep -A3 LC_BUILD_VERSION | head -4
"$MAMP/bin/php" -r 'echo "zlib linked: ", ZLIB_VERSION, PHP_EOL;' 2>/dev/null || true
