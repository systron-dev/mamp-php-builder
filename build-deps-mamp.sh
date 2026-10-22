#!/bin/bash
# Phase A dependency modernization for MAMP Library.
# Rebuilds libraries whose sonames stay ABI-compatible, so existing PHP builds
# keep loading. Sources are verified against MacPorts portfile checksums.
#
# OpenSSL: static libs only. MAMP's dynamic libssl/libcrypto 1.0.0 stay in place
# for MAMP's own binaries; PHP links OpenSSL statically.
#
# Usage: bash build-deps-mamp.sh [all|openssl|nghttp2|curl|libpng|freetype|libxslt|libzip|tidy|libsodium|webp|oniguruma]

set -e

MAMP=/Applications/MAMP/Library
BUILD="/tmp/php-build-${USER:-mamp}/deps-phase-a"
SRC="$BUILD/src"
BACKUP="$BUILD/backup"
ARCH=$(uname -m)
DEPLOY="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
STAMP=$(date +%Y%m%d-%H%M%S)
NCPU=$(sysctl -n hw.ncpu)

export MACOSX_DEPLOYMENT_TARGET="$DEPLOY"
export CFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOY"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOY"
export PATH="$MAMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "==> $*"; }

mkdir -p "$SRC" "$BACKUP"

# Bootstrap cmake if missing (same universal build used by build-mamp-ext.sh)
CMAKE_BIN="$BUILD/cmake-bin"
if ! command -v cmake >/dev/null 2>&1; then
  if [ ! -x "$CMAKE_BIN/cmake" ]; then
    CMAKE_VER=3.29.6
    CMAKE_DIR="cmake-${CMAKE_VER}-macos-universal"
    log "cmake not found — downloading $CMAKE_VER"
    curl -fsSL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VER}/${CMAKE_DIR}.tar.gz" \
      | tar xz -C "$BUILD"
    mkdir -p "$CMAKE_BIN"
    ln -sf "$BUILD/${CMAKE_DIR}/CMake.app/Contents/bin/cmake" "$CMAKE_BIN/cmake"
    ln -sf "$BUILD/${CMAKE_DIR}/CMake.app/Contents/bin/ctest" "$CMAKE_BIN/ctest"
    ln -sf "$BUILD/${CMAKE_DIR}/CMake.app/Contents/bin/cpack" "$CMAKE_BIN/cpack"
  fi
  export PATH="$CMAKE_BIN:$PATH"
fi

# Move existing files matching a glob into the backup dir before install.
stash() {
  local pattern="$1"
  for f in $pattern; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    local base
    base=$(basename "$f")
    [ -e "$BACKUP/$base.bak-$STAMP" ] && continue
    mv "$f" "$BACKUP/$base.bak-$STAMP"
  done
}

fetch() {
  local name="$1" url="$2" sha="$3" ext="$4"
  local tarball="$SRC/$name.tar.$ext"
  local dir="$SRC/$name"
  if [ ! -d "$dir" ]; then
    log "fetch $name"
    curl -fsSL "$url" -o "$tarball"
    echo "$sha  $tarball" | shasum -a 256 -c -
    mkdir -p "$dir"
    tar xf "$tarball" -C "$dir" --strip-components=1
  fi
}

hide_ssl() {
  for f in libssl.dylib libcrypto.dylib; do
    [ -L "$MAMP/lib/$f" ] && mv "$MAMP/lib/$f" "$MAMP/lib/$f.hidden"
  done
}
restore_ssl() {
  for f in libssl.dylib libcrypto.dylib; do
    [ -L "$MAMP/lib/$f.hidden" ] && mv "$MAMP/lib/$f.hidden" "$MAMP/lib/$f"
  done
  return 0
}
trap restore_ssl EXIT

# Install into a staging prefix first, then copy into MAMP. MAMP's
# lib/pkgconfig is owned by another user, so direct `make install` aborts there.
STAGE_ROOT="$BUILD/stage"
copy_stage() {
  local lib="$1"
  rsync -a --exclude='pkgconfig' --exclude='*.pc' \
    "$STAGE_ROOT/$lib$MAMP/" "$MAMP/"
}
stage_autotools() {
  local lib="$1"
  rm -rf "$STAGE_ROOT/$lib"
  make install DESTDIR="$STAGE_ROOT/$lib"
  copy_stage "$lib"
}
stage_cmake() {
  local lib="$1" builddir="$2"
  rm -rf "$STAGE_ROOT/$lib"
  DESTDIR="$STAGE_ROOT/$lib" cmake --install "$builddir"
  copy_stage "$lib"
}

build_openssl() {
  local V=3.6.5
  fetch openssl-3.6.5 \
    "https://www.openssl.org/source/openssl-$V.tar.gz" \
    "a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98" gz
  cd "$SRC/openssl-3.6.5"
  local target="darwin64-${ARCH}-cc"
  ./Configure --prefix="$MAMP" --openssldir="$MAMP/openssl" \
    no-shared no-tests "$target"
  make -j"$NCPU" build_libs
  stash "$MAMP/lib/libssl.a"; stash "$MAMP/lib/libcrypto.a"
  install -m 644 libssl.a libcrypto.a "$MAMP/lib/"
  # Refresh public headers only; leave MAMP's dynamic 1.0.0 libs untouched.
  rsync -a include/openssl/ "$MAMP/include/openssl/"
}

build_nghttp2() {
  local V=1.70.0
  fetch nghttp2-1.70.0 \
    "https://github.com/nghttp2/nghttp2/releases/download/v$V/nghttp2-$V.tar.xz" \
    "e05cb1388eaca3830aded4ccf20044b6e1ac1a61411dcca11b0437c4285c8bc2" xz
  cd "$SRC/nghttp2-1.70.0"
  ./configure --prefix="$MAMP" --enable-lib-only \
    --disable-examples --disable-app --disable-python-bindings
  make -j"$NCPU"
  stash "$MAMP/lib/libnghttp2*"; stash "$MAMP/lib/pkgconfig/libnghttp2.pc"
  stage_autotools nghttp2
}

build_curl() {
  local V=8.23.0
  fetch curl-8.23.0 \
    "https://curl.se/download/curl-$V.tar.xz" \
    "8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5" xz
  cd "$SRC/curl-8.23.0"
  hide_ssl
  ./configure --prefix="$MAMP" \
    --with-openssl="$MAMP" --with-zlib="$MAMP" --with-nghttp2="$MAMP" \
    --with-ldap="$MAMP" --without-libidn2 --without-libpsl \
    --without-brotli --without-zstd --disable-ldaps
  make -j"$NCPU"
  stash "$MAMP/lib/libcurl*"; stash "$MAMP/bin/curl"
  stash "$MAMP/include/curl/*.h"
  stage_autotools curl
  restore_ssl
}

build_libpng() {
  local V=1.6.59
  fetch libpng-1.6.59 \
    "https://download.sourceforge.net/libpng/libpng-$V.tar.xz" \
    "d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389" xz
  cd "$SRC/libpng-1.6.59"
  ./configure --prefix="$MAMP"
  make -j"$NCPU"
  stash "$MAMP/lib/libpng*"; stash "$MAMP/include/png*.h"
  stage_autotools libpng
}

build_freetype() {
  local V=2.15.0
  fetch freetype-2.15.0 \
    "https://download.sourceforge.net/freetype/freetype2/$V/freetype-$V.tar.xz" \
    "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5" xz
  cd "$SRC/freetype-2.15.0"
  ./configure --prefix="$MAMP" --with-zlib="$MAMP" --with-bzip2="$MAMP" \
    --with-png="$MAMP" --without-harfbuzz --without-brotli
  make -j"$NCPU"
  stash "$MAMP/lib/libfreetype*"; stash "$MAMP/include/freetype2/freetype/*.h"
  stage_autotools freetype
}

build_libxslt() {
  local V=1.1.45
  fetch libxslt-1.1.45 \
    "https://download.gnome.org/sources/libxslt/1.1/libxslt-$V.tar.xz" \
    "9acfe68419c4d06a45c550321b3212762d92f41465062ca4ea19e632ee5d216e" xz
  cd "$SRC/libxslt-1.1.45"
  ./configure --prefix="$MAMP" --with-libxml-prefix="$MAMP" \
    --without-python --without-crypto
  make -j"$NCPU"
  stash "$MAMP/lib/libxslt*"; stash "$MAMP/lib/libexslt*"
  stash "$MAMP/include/libxslt/*.h"
  stage_autotools libxslt
}

build_libzip() {
  local V=1.12
  fetch libzip-1.12 \
    "https://libzip.org/download/libzip-$V.tar.xz" \
    "376908d0f0fda13180a19fdc4f7062a1abfb59e09ca07a392d361253b8e60c2b" xz
  cd "$SRC/libzip-1.12"
  cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$MAMP" \
    -DCMAKE_PREFIX_PATH="$MAMP" -DBUILD_SHARED_LIBS=ON \
    -DBUILD_DOC=OFF -DBUILD_EXAMPLES=OFF -DBUILD_REGRESS=OFF \
    -DENABLE_BZIP2=ON -DENABLE_LZMA=ON -DENABLE_ZSTD=OFF
  cmake --build build -j"$NCPU"
  stash "$MAMP/lib/libzip*"; stash "$MAMP/include/zip*.h"
  stage_cmake libzip build
}

build_tidy() {
  local V=5.8.0
  fetch tidy-html5-5.8.0 \
    "https://distfiles.macports.org/tidy/tidy-html5-$V.tar.gz" \
    "2fc78c4369cde9a80f4ae3961880bd003ac31e8b160f6b9422645bab3be5a6cf" gz
  cd "$SRC/tidy-html5-5.8.0"
  cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$MAMP" \
    -DCMAKE_PREFIX_PATH="$MAMP" -DBUILD_SHARED_LIB=ON
  cmake --build build -j"$NCPU"
  stash "$MAMP/lib/libtidy*"; stash "$MAMP/include/tidy*.h"
  stage_cmake tidy build
}

build_libsodium() {
  local V=1.0.22
  fetch libsodium-1.0.22 \
    "https://download.libsodium.org/libsodium/releases/libsodium-$V.tar.gz" \
    "adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349" gz
  cd "$SRC/libsodium-1.0.22"
  ./configure --prefix="$MAMP"
  make -j"$NCPU"
  stash "$MAMP/lib/libsodium*"; stash "$MAMP/include/sodium/*.h"
  stage_autotools libsodium
}

build_webp() {
  local V=1.6.0
  fetch libwebp-1.6.0 \
    "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$V.tar.gz" \
    "e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564" gz
  cd "$SRC/libwebp-1.6.0"
  ./configure --prefix="$MAMP" --enable-libwebpdemux --enable-libwebpmux
  make -j"$NCPU"
  stash "$MAMP/lib/libwebp*"; stash "$MAMP/include/webp/*.h"
  stage_autotools webp
}

build_oniguruma() {
  local V=6.9.10
  fetch oniguruma-6.9.10 \
    "https://distfiles.macports.org/oniguruma6/oniguruma-$V.tar.gz" \
    "dd1131ff9a06ccc00b5833858069f390f6d8239489a4bdb518885ac10c68334b" gz
  cd "$SRC/oniguruma-6.9.10"
  # MacPorts distfile is a git snapshot without a generated configure script.
  cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$MAMP" \
    -DCMAKE_PREFIX_PATH="$MAMP" -DBUILD_SHARED_LIBS=ON
  cmake --build build -j"$NCPU"
  stash "$MAMP/lib/libonig*"; stash "$MAMP/include/oniguruma.h"
  stage_cmake oniguruma build
}

TARGET="${1:-all}"
case "$TARGET" in
  openssl)    build_openssl ;;
  nghttp2)    build_nghttp2 ;;
  curl)       build_curl ;;
  libpng)     build_libpng ;;
  freetype)   build_freetype ;;
  libxslt)    build_libxslt ;;
  libzip)     build_libzip ;;
  tidy)       build_tidy ;;
  libsodium)  build_libsodium ;;
  webp)       build_webp ;;
  oniguruma)  build_oniguruma ;;
  all)
    build_openssl
    build_nghttp2
    build_curl
    build_libpng
    build_freetype
    # libxslt 1.1.45 requires libxml2 >= 2.15.1 (phase B); run `libxslt`
    # explicitly after libxml2 is upgraded.
    build_libzip
    build_tidy
    build_libsodium
    build_webp
    build_oniguruma
    ;;
  *) echo "Unknown target: $TARGET"; exit 1 ;;
esac

log "DONE: $TARGET"
log "Backups in $BACKUP"
