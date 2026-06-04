#!/bin/bash
# Build libcurl from source for MAMP, statically embedding OpenSSL 3.x
# Replaces MAMP's libcurl 7.68.0 (linked against old OpenSSL 1.0.2u).
#
# Strategy: temporarily hide libssl.dylib + libcrypto.dylib symlinks so the
# linker can only find the OpenSSL 3 .a files and links them statically.
# Symlinks are restored when script exits (via trap).
#
# PREREQUISITE: OpenSSL 3.x must be built into /Applications/MAMP/Library
#   (libssl.a + libcrypto.a in lib/, headers in include/openssl/)
# Usage: bash build-curl-mamp.sh [curl-version]  (default: 8.7.1)

set -e

CURL_VERSION="${1:-8.7.1}"
ARCH=$(uname -m)   # arm64 on Apple Silicon, x86_64 on Intel
MAMP=/Applications/MAMP/Library
BUILD="/tmp/php-build-${USER:-mamp}"
SRC="${BUILD}/curl-${CURL_VERSION}"
TARBALL="${BUILD}/curl-${CURL_VERSION}.tar.gz"

echo "==> Building curl ${CURL_VERSION} for MAMP (OpenSSL 3 static)"

# Verify OpenSSL 3 static libs present
if [ ! -f "$MAMP/lib/libssl.a" ] || [ ! -f "$MAMP/lib/libcrypto.a" ]; then
  echo "ERROR: $MAMP/lib/libssl.a or libcrypto.a missing. Build OpenSSL 3 first."
  exit 1
fi
OSSL_VER=$(grep "OPENSSL_VERSION_NUMBER" "$MAMP/include/openssl/opensslv.h" 2>/dev/null | head -1)
if echo "$OSSL_VER" | grep -q "0x100"; then
  echo "ERROR: OpenSSL headers in MAMP are still 1.0.x. Update headers first."
  exit 1
fi

# Download source if needed
if [ ! -d "$SRC" ]; then
  mkdir -p "$BUILD"
  if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading curl ${CURL_VERSION}..."
    cd "$BUILD"
    curl -L -O "https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
  fi
  echo "==> Extracting..."
  cd "$BUILD"
  tar xzf "curl-${CURL_VERSION}.tar.gz"
fi

# Back up existing curl lib (once only)
if [ -f "$MAMP/lib/libcurl.4.dylib" ] && [ ! -f "$MAMP/lib/libcurl.4.dylib.bak" ]; then
  echo "==> Backing up original libcurl.4.dylib..."
  cp "$MAMP/lib/libcurl.4.dylib" "$MAMP/lib/libcurl.4.dylib.bak"
fi

export PATH="$MAMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- Hide old OpenSSL dylib symlinks so linker falls back to .a (OpenSSL 3) ---
LIBSSL_SYMLINK="$MAMP/lib/libssl.dylib"
LIBCRYPTO_SYMLINK="$MAMP/lib/libcrypto.dylib"
LIBSSL_MOVED=0
LIBCRYPTO_MOVED=0

restore_symlinks() {
  if [ $LIBSSL_MOVED -eq 1 ]; then
    mv "$MAMP/lib/libssl.dylib.hidden" "$LIBSSL_SYMLINK" 2>/dev/null && echo "==> Restored libssl.dylib"
  fi
  if [ $LIBCRYPTO_MOVED -eq 1 ]; then
    mv "$MAMP/lib/libcrypto.dylib.hidden" "$LIBCRYPTO_SYMLINK" 2>/dev/null && echo "==> Restored libcrypto.dylib"
  fi
}
trap restore_symlinks EXIT

if [ -L "$LIBSSL_SYMLINK" ]; then
  mv "$LIBSSL_SYMLINK" "$MAMP/lib/libssl.dylib.hidden"
  LIBSSL_MOVED=1
  echo "==> Hid libssl.dylib (will restore on exit)"
fi
if [ -L "$LIBCRYPTO_SYMLINK" ]; then
  mv "$LIBCRYPTO_SYMLINK" "$MAMP/lib/libcrypto.dylib.hidden"
  LIBCRYPTO_MOVED=1
  echo "==> Hid libcrypto.dylib (will restore on exit)"
fi
# -----------------------------------------------------------------------------

cd "$SRC"

# Clean previous build artifacts
if [ -f "Makefile" ]; then
  echo "==> Cleaning previous build..."
  make distclean 2>/dev/null || make clean 2>/dev/null || true
fi

echo "==> Configuring curl ${CURL_VERSION}..."
./configure \
  --prefix="$MAMP" \
  --with-openssl="$MAMP" \
  --with-nghttp2="$MAMP" \
  --with-ldap \
  --without-brotli \
  --without-zstd \
  --enable-shared \
  --disable-static \
  --with-zlib="$MAMP" \
  CFLAGS="-arch $ARCH" \
  LDFLAGS="-arch $ARCH -L$MAMP/lib"

echo "==> Building curl ${CURL_VERSION} ($(sysctl -n hw.ncpu) cores)..."
make -j$(sysctl -n hw.ncpu)

echo "==> Installing curl ${CURL_VERSION} into $MAMP..."
make install

echo ""
echo "==> Checking libcurl OpenSSL dependencies (should be empty — OpenSSL embedded):"
otool -L "$MAMP/lib/libcurl.4.dylib" | grep -E "ssl|crypto" || echo "  (none — good!)"

echo ""
echo "==> Done. New curl:"
"$MAMP/bin/curl" --version | head -2
