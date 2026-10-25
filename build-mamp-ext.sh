#!/bin/bash
# Build missing PHP extensions for MAMP PHP 8.2.35, 8.3.36, 8.4.27, 8.5.12
# All deps built from source — no Homebrew dependencies
# Usage: ./build-mamp-ext.sh [target]
# Targets: all | deps | ext | <specific> (see case block at bottom)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Paths ─────────────────────────────────────────────────────────────────────
MAMP=/Applications/MAMP
MAMPLIB=$MAMP/Library
PHP82=$MAMP/bin/php/php8.2.35
PHP83=$MAMP/bin/php/php8.3.36
PHP84=$MAMP/bin/php/php8.4.27
PHP85=$MAMP/bin/php/php8.5.12
PHP86=$MAMP/bin/php/php8.6.0
EXT82=$PHP82/lib/php/extensions/no-debug-non-zts-20220829
EXT83=$PHP83/lib/php/extensions/no-debug-non-zts-20230831
EXT84=$PHP84/lib/php/extensions/no-debug-non-zts-20240924
EXT85=$PHP85/lib/php/extensions/no-debug-non-zts-20250925
EXT86=$PHP86/lib/php/extensions/no-debug-non-zts-20260924
BUILD="/tmp/php-build-${USER:-mamp}"
DEPS=$BUILD/ext-deps        # static libs installed here
# Prefer our own *-config tools over MacPorts copies of the same name.
export PATH="$DEPS/bin:$PATH"
SRC=$BUILD/ext-src          # source trees unpacked here
NCPU=$(sysctl -n hw.ncpu)
# Native-only: arm64 on Apple Silicon, x86_64 on Intel (ignores Rosetta process arch).
source "$(cd "$(dirname "$0")" && pwd)/lib-arch.sh"
reap_workcopies "$BUILD"

# ── Versions ──────────────────────────────────────────────────────────────────
LIBYAML_VER=0.2.5
LIBSSH2_VER=1.11.1
LIBMCRYPT_VER=2.5.8
LIBMEMCACHED_VER=1.1.4
PG_VER=16.3
LIBJPEG_VER=3.0.3
LIBPNG_VER=1.6.43
LIBTIFF_VER=4.6.0
LIBWEBP_VER=1.4.0
FREETYPE_VER=2.13.2
IMAGEMAGICK_VER=7.1.1-33
LIBYAZ_VER=5.34.0

APCU_VER=5.1.24
IGBINARY_VER=3.2.16
OAUTH_VER=2.0.10
OAUTH_VER85=2.0.10
REDIS_VER=6.3.0
UPLOADPROGRESS_VER=2.0.2
XDEBUG_VER=3.5.3
XDEBUG_VER85=3.5.3
# 3.6.0alpha1 is the first release accepting PHP 8.6 (gate: >= 8.2, < 8.7)
# and it carries its own PHP_VERSION_ID >= 80600 fixes. Not on PECL — alpha.
XDEBUG_VER86=3.6.0alpha1
YAML_VER=2.2.4
SSH2_VER=1.5.0
MCRYPT_VER=1.0.9
MEMCACHED_VER=3.4.0
MEMCACHED_VER85=3.4.0
IMAGICK_VER=3.7.0
YAZ_VER=1.2.4

# ── Init ──────────────────────────────────────────────────────────────────────
mkdir -p "$DEPS/lib" "$DEPS/include" "$DEPS/bin" "$SRC"

# Bootstrap cmake if not on PATH — download universal binary from cmake.org
CMAKE_BIN=$BUILD/cmake-bin
if ! command -v cmake &>/dev/null; then
  if [ ! -x "$CMAKE_BIN/cmake" ]; then
    CMAKE_VER=3.29.6
    CMAKE_DIR="cmake-${CMAKE_VER}-macos-universal"
    echo "[BUILD] cmake not found — downloading cmake $CMAKE_VER..."
    curl -fsSL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VER}/${CMAKE_DIR}.tar.gz" \
      | tar xz -C "$BUILD"
    mkdir -p "$CMAKE_BIN"
    ln -sf "$BUILD/${CMAKE_DIR}/CMake.app/Contents/bin/cmake"  "$CMAKE_BIN/cmake"
    ln -sf "$BUILD/${CMAKE_DIR}/CMake.app/Contents/bin/ctest"  "$CMAKE_BIN/ctest"
    ln -sf "$BUILD/${CMAKE_DIR}/CMake.app/Contents/bin/cpack"  "$CMAKE_BIN/cpack"
    echo "[BUILD] cmake installed to $CMAKE_BIN"
  fi
  export PATH="$CMAKE_BIN:$PATH"
fi

export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$MAMPLIB/lib/pkgconfig"
export PATH="$DEPS/bin:$PHP85/bin:$PHP84/bin:$PHP83/bin:$PHP82/bin:$PATH"
# Handle MACOSX_DEPLOYMENT_TARGET. If not set, prompt if interactive, or default to 12.0
if [ -z "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  if [ -t 0 ]; then
    read -p "Enter target macOS version for the build (e.g. 12.0, 13.0, 14.0, 15.0) [default: 12.0]: " TARGET_VAL
    export MACOSX_DEPLOYMENT_TARGET="${TARGET_VAL:-12.0}"
  else
    export MACOSX_DEPLOYMENT_TARGET="12.0"
  fi
fi
echo "==> macOS Deployment Target: $MACOSX_DEPLOYMENT_TARGET"

# Deliberately ignore an inherited CFLAGS: a Rosetta shell may carry
# -arch x86_64, which would defeat the native-only guarantee.
export CFLAGS="-O2 -g -arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CXXFLAGS="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -isystem $(xcrun --sdk macosx --show-sdk-path)/usr/include/c++/v1"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[BUILD]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight() {
  local fail=0
  for cmd in cmake curl tar make; do
    command -v "$cmd" &>/dev/null || { err "Missing: $cmd"; fail=1; }
  done
  [ -f "$MAMPLIB/lib/libssl.a" ]    || { err "Missing $MAMPLIB/lib/libssl.a — build OpenSSL 3 first"; fail=1; }
  [ -f "$MAMPLIB/lib/libcrypto.a" ] || { err "Missing $MAMPLIB/lib/libcrypto.a — build OpenSSL 3 first"; fail=1; }
  # Static libs must be native; a Library tree populated on the other arch fails late.
  [ $fail -eq 0 ] && require_native_mamp_libs "$MAMPLIB"
  [ -x "$PHP82/bin/phpize" ]        || { err "Missing $PHP82/bin/phpize"; fail=1; }
  [ -x "$PHP83/bin/phpize" ]        || { err "Missing $PHP83/bin/phpize"; fail=1; }
  [ -x "$PHP84/bin/phpize" ]        || { err "Missing $PHP84/bin/phpize"; fail=1; }
  [ -x "$PHP85/bin/phpize" ]        || { err "Missing $PHP85/bin/phpize"; fail=1; }
  if [ "$TARGET" = "ext86" ] || [ -d "$PHP86" ]; then
    [ -x "$PHP86/bin/phpize" ]      || { err "Missing $PHP86/bin/phpize"; fail=1; }
  fi
  [ $fail -eq 0 ] || exit 1

  # Create php_smart_string.h shim for PHP 8.5 & PHP 8.6
  for phpdir in "$PHP85" "$PHP86"; do
    local smart_string_h="$phpdir/include/php/ext/standard/php_smart_string.h"
    if [ -d "$(dirname "$smart_string_h")" ] && [ ! -f "$smart_string_h" ]; then
      printf '#pragma once\n#include "Zend/zend_smart_string.h"\n' > "$smart_string_h"
      log "Created php_smart_string.h shim for $(basename $phpdir)"
    fi
  done
}

# ── OpenSSL dylib hide/restore ─────────────────────────────────────────────────
# Shared helpers in lib-arch.sh; they test for symlinks, so a dangling
# libssl.dylib is still hidden and restored correctly.
hide_mamp_ssl()    { hide_openssl_dylibs "$MAMPLIB/lib"; }
restore_mamp_ssl() { restore_openssl_dylibs "$MAMPLIB/lib"; }
trap restore_mamp_ssl EXIT INT TERM

# ── Download helpers ──────────────────────────────────────────────────────────
fetch_tar() {
  local url=$1 dir=$2
  if [ -d "$SRC/$dir" ]; then log "  skip download: $dir"; return; fi
  log "  fetch: $(basename $url)"
  curl -fsSL "$url" | tar xz -C "$SRC" || { echo "ERROR: fetch failed: $url" >&2; return 1; }
}

fetch_pecl() {
  local pkg=$1 ver=$2
  [ -d "$SRC/${pkg}-${ver}" ] && { log "  skip download: $pkg-$ver"; return; }
  log "  fetch PECL: $pkg-$ver"
  curl -fsSL "https://pecl.php.net/get/${pkg}-${ver}.tgz" | tar xz -C "$SRC" \
    || { echo "ERROR: PECL fetch failed: $pkg-$ver" >&2; return 1; }
}

# ── Extension build core ──────────────────────────────────────────────────────
# Builds one extension against one PHP version. Env vars LDFLAGS/LIBS/CPPFLAGS
# are forwarded to configure and make if set.
_build_ext_one() {
  local phpdir=$1 extdir=$2 srcdir=$3 configure_args="${4:-}"
  log "    → PHP $(basename $phpdir)"
  cd "$srcdir" || return 1
  "$phpdir/bin/phpize" --clean 2>/dev/null || true
  "$phpdir/bin/phpize" || return 1
  # pcre2.h lives in MAMP Library — not searched by default phpize builds.
  # PHP 8.6 also gets a compat header for removed zval/INI macros.
  local compat_flag=""
  [ "$phpdir" = "$PHP86" ] && compat_flag="-include $SCRIPT_DIR/php86-compat.h"
  CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I$MAMPLIB/include $compat_flag" \
    ./configure --with-php-config="$phpdir/bin/php-config" $configure_args || return 1
  if [ -f Makefile ]; then
    sed -i.bak -E 's/^([A-Z_]+_SHARED_LIBADD = .* -lpq)/\1 -lpgcommon -lpgport -lssl -lcrypto -lz/g' Makefile || true
  fi
  # memcached: link the split-out hashkit library (see lib-arch.sh).
  patch_hashkit_makefile "$srcdir" || return 1

  # imagick: libtool drops the static Magick coder objects unless force-loaded.
  if [ -f Makefile ] && [[ "$(basename "$srcdir")" == *imagick-* ]]; then
    local IMAGICK_DEPS="-Wl,-force_load,$DEPS/lib/libMagickWand-7.Q16HDRI.a -Wl,-force_load,$DEPS/lib/libMagickCore-7.Q16HDRI.a $DEPS/lib/libjbig.a $DEPS/lib/libtiff.a $DEPS/lib/libfreetype.a $DEPS/lib/libjxl.a $DEPS/lib/libhwy.a $DEPS/lib/libbrotlienc.a $DEPS/lib/libbrotlidec.a $DEPS/lib/libbrotlicommon.a $DEPS/lib/libjxl_cms.a $DEPS/lib/libjxl_threads.a $DEPS/lib/libpng16.a $DEPS/lib/libdjvulibre.a $DEPS/lib/libjpeg.a $DEPS/lib/libwebpmux.a $DEPS/lib/libwebpdemux.a $DEPS/lib/libwebp.a $DEPS/lib/libsharpyuv.a -L$MAMPLIB/lib -llzma -lbz2 -lz -lzip -lm -lpthread -framework CoreFoundation"
    sed -i.bak -E "s|^IMAGICK_SHARED_LIBADD = .*|IMAGICK_SHARED_LIBADD = -Wl,-rpath,$DEPS/lib -L$DEPS/lib $IMAGICK_DEPS|" Makefile
  fi
  make -j$NCPU || return 1
  # Normalize and sign the build-tree modules before installing them. Signing
  # only after the copy leaves macOS rejecting the bundle on arm64
  # ("CODESIGNING: Invalid Page"); normalizing first also means an unresolved
  # dependency fails the build instead of shipping a module with a /tmp rpath.
  if [ ! -d modules ]; then
    err "    ✗ no modules were built in $srcdir"
    return 1
  fi
  log "    → Normalizing + code-signing modules/*.so, then installing"
  local install_rc=0
  install_modules "$extdir" || install_rc=$?
  if [ "$install_rc" -eq 0 ]; then
    log "    ✓ copied to $extdir"
  elif [ "$install_rc" -eq 3 ] || [ "$install_rc" -eq 4 ]; then
    return 1
  else
    local local_dist="$SCRIPT_DIR/dist/$(basename "$phpdir")"
    mkdir -p "$local_dist"
    # Modules are already signed in the build tree; verify before offering
    # them as a dist fallback.
    for f in modules/*.so; do
      [ -f "$f" ] || continue
      if ! codesign --verify "$f" 2>/dev/null; then
        err "    ✗ $f is not signed; refusing the dist fallback"
        return 1
      fi
    done
    if cp modules/*.so "$local_dist/"; then
      warn "    ! Could not write to $extdir. Copied to $local_dist instead."
      return 0
    fi
    err "    ✗ could not copy modules to $extdir or $local_dist"
    return 1
  fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
TARGET="${1:-all}"
preflight

# Build extension for PHP 8.2-8.5
build_ext_both() {
  local srcdir=$1 configure_args="${2:-}" rc=0
  _build_ext_one "$PHP82" "$EXT82" "$srcdir" "$configure_args" || rc=$?
  _build_ext_one "$PHP83" "$EXT83" "$srcdir" "$configure_args" || rc=$?
  _build_ext_one "$PHP84" "$EXT84" "$srcdir" "$configure_args" || rc=$?
  _build_ext_one "$PHP85" "$EXT85" "$srcdir" "$configure_args" || rc=$?
  return $rc
}

# Build extension for PHP 8.5 only
build_ext_85only() {
  local srcdir=$1 configure_args="${2:-}"
  _build_ext_one "$PHP85" "$EXT85" "$srcdir" "$configure_args"
}

# Build extension for PHP 8.6 only
build_ext_86only() {
  local srcdir=$1 configure_args="${2:-}"
  _build_ext_one "$PHP86" "$EXT86" "$srcdir" "$configure_args"
}

# Soft-fail wrapper: log warning but don't abort the whole build
try_build() {
  local name=$1; shift
  if "$@"; then
    log "✓ $name done"
  else
    warn "✗ $name FAILED — skipping, check output above"
  fi
  return 0
}

# ── PHASE 1: C Library Dependencies ───────────────────────────────────────────

build_libyaml() {
  log "── libyaml $LIBYAML_VER ──"
  local DIR="yaml-$LIBYAML_VER"
  fetch_tar "https://pyyaml.org/download/libyaml/yaml-$LIBYAML_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  ./configure --prefix="$DEPS" --enable-static --disable-shared
  make -j$NCPU && make install
}

build_libssh2() {
  log "── libssh2 $LIBSSH2_VER ──"
  local DIR="libssh2-$LIBSSH2_VER"
  fetch_tar "https://www.libssh2.org/download/libssh2-$LIBSSH2_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  hide_mamp_ssl
  ./configure --prefix="$DEPS" --enable-static --disable-shared \
    --with-crypto=openssl \
    CPPFLAGS="-I$MAMPLIB/include" \
    LDFLAGS="-L$MAMPLIB/lib" \
    LIBS="-lssl -lcrypto"
  make -j$NCPU && make install
  restore_mamp_ssl
}

build_libmcrypt() {
  log "── libmcrypt $LIBMCRYPT_VER ──"
  local DIR="libmcrypt-$LIBMCRYPT_VER"
  fetch_tar "https://sourceforge.net/projects/mcrypt/files/Libmcrypt/$LIBMCRYPT_VER/libmcrypt-$LIBMCRYPT_VER.tar.gz/download" "$DIR"
  cd "$SRC/$DIR"
  # config.sub too old for arm-apple-darwin — replace with MacPorts modern version
  cp /opt/local/share/autoconf/build-aux/config.sub config.sub
  cp /opt/local/share/autoconf/build-aux/config.guess config.guess 2>/dev/null || true
  chmod +x config.sub config.guess 2>/dev/null || true
  # clang compat: disable posix threads to avoid old pthread API issues
  CFLAGS="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -std=gnu89 -Wno-implicit-function-declaration -Wno-implicit-int" \
  ./configure --prefix="$DEPS" --enable-static --disable-shared \
    --disable-posix-threads
  make -j$NCPU && make install
}

build_libmemcached() {
  log "── libmemcached-awesome $LIBMEMCACHED_VER ──"
  local DIR="libmemcached-$LIBMEMCACHED_VER"
  fetch_tar "https://github.com/awesomized/libmemcached/archive/refs/tags/$LIBMEMCACHED_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  mkdir -p build && cd build
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_SASL=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=$ARCH
  make -j$NCPU && make install
  # 1.1.4's pkg-config omits the split-out static hashkit library; without it
  # the memcached module binds hashkit_* to 0x0 and crashes on first use.
  local pc="$DEPS/lib/pkgconfig/libmemcached.pc"
  if [ -f "$pc" ] && ! grep -q -- '-lhashkit' "$pc"; then
    sed -i.bak -E 's|^(Libs: .*)$|\1 -lhashkit|' "$pc"
  fi
}

build_libpq() {
  log "── PostgreSQL $PG_VER (libpq only) ──"
  local DIR="postgresql-$PG_VER"
  fetch_tar "https://ftp.postgresql.org/pub/source/v$PG_VER/postgresql-$PG_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  hide_mamp_ssl
  # Build just enough for libpq — no server, no readline, no ICU/zlib to keep it clean
  ./configure --prefix="$DEPS" \
    --without-readline \
    --with-ssl=openssl \
    --without-icu \
    --without-zlib \
    CPPFLAGS="-I$MAMPLIB/include" \
    LDFLAGS="-L$MAMPLIB/lib" \
    CFLAGS="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Wno-unguarded-availability-new"
  # Build only static libpq.a — skip dylib (dylib check fails: OpenSSL calls atexit)
  make -j$NCPU -C src/interfaces/libpq libpq.a
  # Manual install — avoid 'make install' which triggers dylib build+check
  mkdir -p "$DEPS/lib" "$DEPS/include"
  cp src/interfaces/libpq/libpq.a "$DEPS/lib/"
  cp src/common/libpgcommon.a "$DEPS/lib/"
  cp src/port/libpgport.a "$DEPS/lib/"
  cp src/interfaces/libpq/libpq-fe.h src/interfaces/libpq/libpq-events.h "$DEPS/include/"
  cp src/include/postgres_ext.h "$DEPS/include/"
  # pg_config — needed by PHP pgsql configure
  make -j$NCPU -C src/bin/pg_config
  cp src/bin/pg_config/pg_config "$DEPS/bin/"
  chmod +x "$DEPS/bin/pg_config"
  make -C src/include install
  restore_mamp_ssl
}

build_libjpeg() {
  log "── libjpeg-turbo $LIBJPEG_VER ──"
  local DIR="libjpeg-turbo-$LIBJPEG_VER"
  fetch_tar "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$LIBJPEG_VER/libjpeg-turbo-$LIBJPEG_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  mkdir -p build && cd build
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=$ARCH
  make -j$NCPU && make install
}

build_libpng() {
  log "── libpng $LIBPNG_VER ──"
  local DIR="libpng-$LIBPNG_VER"
  fetch_tar "https://sourceforge.net/projects/libpng/files/libpng16/$LIBPNG_VER/libpng-$LIBPNG_VER.tar.gz/download" "$DIR"
  cd "$SRC/$DIR"
  ./configure --prefix="$DEPS" --enable-static --disable-shared \
    CPPFLAGS="-I$DEPS/include -I$MAMPLIB/include" \
    LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  make -j$NCPU && make install
}

build_libtiff() {
  log "── libtiff $LIBTIFF_VER ──"
  local DIR="tiff-$LIBTIFF_VER"
  fetch_tar "https://download.osgeo.org/libtiff/tiff-$LIBTIFF_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  ./configure --prefix="$DEPS" --enable-static --disable-shared \
    --without-x \
    CPPFLAGS="-I$DEPS/include -I$MAMPLIB/include" \
    LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  make -j$NCPU && make install
}

build_libwebp() {
  log "── libwebp $LIBWEBP_VER ──"
  local DIR="libwebp-$LIBWEBP_VER"
  fetch_tar "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$LIBWEBP_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  ./configure --prefix="$DEPS" --enable-static --disable-shared \
    CPPFLAGS="-I$DEPS/include" \
    LDFLAGS="-L$DEPS/lib"
  make -j$NCPU && make install
}

build_freetype() {
  log "── freetype $FREETYPE_VER ──"
  local DIR="freetype-$FREETYPE_VER"
  fetch_tar "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  ./configure --prefix="$DEPS" --enable-static --disable-shared \
    --with-zlib=no \
    --without-harfbuzz \
    --without-brotli \
    CPPFLAGS="-I$DEPS/include" \
    LDFLAGS="-L$DEPS/lib"
  make -j$NCPU && make install
  # Scrub MacPorts paths freetype's libtool archive records despite
  # --without-harfbuzz, so dependent modules stay self-contained.
  if [ -f "$DEPS/lib/libfreetype.la" ]; then
    sed -i.bak -E "s#-L/opt/local/lib ##g; s#-lharfbuzz ##g" "$DEPS/lib/libfreetype.la"
  fi
}

build_imagemagick() {
  log "── ImageMagick $IMAGEMAGICK_VER ──"
  # Fetch — GitHub archive extracts to ImageMagick-VERSION
  local DIR="ImageMagick-$IMAGEMAGICK_VER"
  fetch_tar "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$IMAGEMAGICK_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  # ImageMagick resolves zlib/libzip only through pkg-config. Provide local .pc
  # files pointing at MAMP Library so no /opt/local search path is needed.
  mkdir -p "$DEPS/lib/pkgconfig"
  cat > "$DEPS/lib/pkgconfig/zlib.pc" <<EOF
prefix=$MAMPLIB
libdir=$MAMPLIB/lib
includedir=$MAMPLIB/include

Name: zlib
Description: zlib compression library
Version: 1.3.2
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
  cat > "$DEPS/lib/pkgconfig/libzip.pc" <<EOF
prefix=$MAMPLIB
libdir=$MAMPLIB/lib
includedir=$MAMPLIB/include

Name: libzip
Description: library for reading/writing zip archives
Version: 1.12
Libs: -L\${libdir} -lzip
Cflags: -I\${includedir}
EOF
  # freetype2.pc Requires bzip2; libtiff-4.pc Requires liblzma.
  cat > "$DEPS/lib/pkgconfig/bzip2.pc" <<EOF
prefix=$MAMPLIB
libdir=$MAMPLIB/lib
includedir=$MAMPLIB/include

Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
EOF
  cat > "$DEPS/lib/pkgconfig/liblzma.pc" <<EOF
prefix=$MAMPLIB
libdir=$MAMPLIB/lib
includedir=$MAMPLIB/include

Name: liblzma
Description: xz compression library
Version: 5.8.4
Libs: -L\${libdir} -llzma
Cflags: -I\${includedir}
EOF
  # freetype2.pc always lists harfbuzz even when built --without-harfbuzz.
  cat > "$DEPS/lib/pkgconfig/harfbuzz.pc" <<EOF
prefix=$MAMPLIB
libdir=$MAMPLIB/lib
includedir=$MAMPLIB/include

Name: harfbuzz
Description: HarfBuzz text shaping (not linked)
Version: 12.0.0
Libs:
Cflags:
EOF
  ./configure --prefix="$DEPS" \
    --enable-static --disable-shared \
    --disable-docs \
    --without-utilities \
    --without-x \
    --without-perl \
    --without-magick-plus-plus \
    --with-jpeg="$DEPS" \
    --with-png=yes \
    --with-tiff=yes \
    --with-webp=yes \
    --with-freetype=yes \
    --without-heic \
    --without-raw \
    --without-gvc \
    --without-fontconfig \
    --without-pango \
    --without-xml \
    --without-lcms \
    --without-openjp2 \
    --without-lqr \
    --without-openexr \
    --with-jbig="$DEPS" \
    --with-jxl="$DEPS" \
    --with-djvu=yes \
    --without-fftw \
    --without-flif \
    --without-fpx \
    --without-wmf \
    --without-autotrace \
    --without-dps \
    --without-rsvg \
    --without-uhdr \
    --without-gslib \
    CPPFLAGS="-I$DEPS/include -I$MAMPLIB/include" \
    LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib" \
    ddjvuapi_CFLAGS="-I$DEPS/include" \
    ddjvuapi_LIBS="-L$DEPS/lib -ldjvulibre" \
    ZLIB_CFLAGS="-I$MAMPLIB/include" \
    ZLIB_LIBS="-L$MAMPLIB/lib -lz" \
    ZIP_CFLAGS="-I$MAMPLIB/include" \
    ZIP_LIBS="-L$MAMPLIB/lib -lzip" \
    LZMA_CFLAGS="-I$MAMPLIB/include" \
    LZMA_LIBS="-L$MAMPLIB/lib -llzma" \
    BZLIB_CFLAGS="-I$MAMPLIB/include" \
    BZLIB_LIBS="-L$MAMPLIB/lib -lbz2" \
    LIBS="-L$DEPS/lib -lbrotlicommon" \
    PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
  make -j$NCPU && make install
}

build_libyaz() {
  log "── libyaz $LIBYAZ_VER ──"
  local DIR="yaz-$LIBYAZ_VER"
  fetch_tar "https://ftp.indexdata.com/pub/yaz/yaz-$LIBYAZ_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  # yaz depends on libxml2 + libxslt — use MAMP's
  ./configure --prefix="$DEPS" --enable-static --disable-shared \
    CPPFLAGS="-I$DEPS/include -I$MAMPLIB/include" \
    LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib" \
    PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$MAMPLIB/lib/pkgconfig"
  make -j$NCPU && make install
}

# ── PHASE 2: PHP Extensions ────────────────────────────────────────────────────

build_apcu() {
  log "── apcu $APCU_VER ──"
  fetch_pecl "apcu" "$APCU_VER"
  build_ext_both "$SRC/apcu-$APCU_VER"
}

build_igbinary() {
  log "── igbinary $IGBINARY_VER ──"
  fetch_pecl "igbinary" "$IGBINARY_VER"
  build_ext_both "$SRC/igbinary-$IGBINARY_VER" || return 1
  # Install igbinary.h so redis/memcached can enable igbinary support
  # Use src/php7/igbinary.h — the root igbinary.h just re-includes it relatively
  local igbinary_h="$SRC/igbinary-$IGBINARY_VER/src/php7/igbinary.h"
  for phpdir in "$PHP82" "$PHP83" "$PHP84" "$PHP85"; do
    local inc="$phpdir/include/php/ext/igbinary"
    mkdir -p "$inc"
    cp "$igbinary_h" "$inc/igbinary.h"
  done
  log "  igbinary.h installed to PHP include dirs"
}

# Fetch, isolate, and patch oauth for one PHP line, then run the given builder.
_build_oauth_for() {
  local ver=$1 builder=$2 DIR
  fetch_pecl "oauth" "$ver"
  DIR=$(workcopy "$SRC/oauth-$ver") || return 1
  # PHP 8.6 removed XtOffsetOf; offsetof is the standard equivalent elsewhere.
  sed -i.bak 's/XtOffsetOf/offsetof/g' "$DIR"/*.h "$DIR"/*.c
  patch_oauth_tree "$DIR" || return 1
  "$builder" "$DIR"
}

build_oauth() {
  log "── oauth $OAUTH_VER ──"
  _build_oauth_for "$OAUTH_VER" build_ext_both
}

build_redis() {
  log "── redis $REDIS_VER ──"
  fetch_pecl "redis" "$REDIS_VER"
  build_ext_both "$SRC/redis-$REDIS_VER" "--enable-redis-igbinary"
}

build_uploadprogress() {
  log "── uploadprogress $UPLOADPROGRESS_VER ──"
  fetch_pecl "uploadprogress" "$UPLOADPROGRESS_VER"
  build_ext_both "$SRC/uploadprogress-$UPLOADPROGRESS_VER"
}

build_xdebug() {
  log "── xdebug $XDEBUG_VER ──"
  fetch_pecl "xdebug" "$XDEBUG_VER"
  # Link zlib from MAMP Library, not /opt/local (self-contained runtime)
  ZLIB_CFLAGS="-I$MAMPLIB/include" ZLIB_LIBS="-L$MAMPLIB/lib -lz" \
    CPPFLAGS="-I$MAMPLIB/include" LDFLAGS="-L$MAMPLIB/lib" \
    build_ext_both "$SRC/xdebug-$XDEBUG_VER"
}

build_yaml_ext() {
  log "── yaml $YAML_VER ──"
  fetch_pecl "yaml" "$YAML_VER"
  build_ext_both "$SRC/yaml-$YAML_VER" "--with-yaml=$DEPS"
}

build_ssh2_ext() {
  log "── ssh2 $SSH2_VER ──"
  fetch_pecl "ssh2" "$SSH2_VER"
  hide_mamp_ssl
  # Need OpenSSL static symbols pulled in since libssh2.a references them
  export LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  export LIBS="-lssl -lcrypto"
  local rc=0
  build_ext_both "$SRC/ssh2-$SSH2_VER" "--with-ssh2=$DEPS" || rc=$?
  unset LDFLAGS LIBS
  restore_mamp_ssl
  return $rc
}

build_mcrypt_ext() {
  log "── mcrypt $MCRYPT_VER ──"
  fetch_pecl "mcrypt" "$MCRYPT_VER"
  local DIR
  DIR=$(workcopy "$SRC/mcrypt-$MCRYPT_VER") || return 1
  # php_rand.h removed in PHP 8.4 — create compat shim if missing
  for phpdir in "$PHP83" "$PHP84" "$PHP85"; do
    local rand_h="$phpdir/include/php/ext/standard/php_rand.h"
    if [ ! -f "$rand_h" ]; then
      printf '#pragma once\n#include "ext/random/php_random.h"\n#ifndef php_rand\n#define php_rand() rand()\n#endif\n' > "$rand_h"
    fi
  done
  build_ext_both "$DIR" "--with-mcrypt=$DEPS"
}

build_memcached_ext() {
  log "── memcached $MEMCACHED_VER ──"
  fetch_pecl "memcached" "$MEMCACHED_VER"
  build_ext_both "$SRC/memcached-$MEMCACHED_VER" \
    "--with-libmemcached-dir=$DEPS --with-zlib-dir=$MAMPLIB --enable-memcached-igbinary --enable-memcached-json --disable-memcached-sasl"
}

build_imagick_ext() {
  log "── imagick $IMAGICK_VER ──"
  fetch_pecl "imagick" "$IMAGICK_VER"
  local DIR
  DIR=$(workcopy "$SRC/imagick-$IMAGICK_VER") || return 1
  # PHP 8.4 removed php_strtolower — patch with inline compat macro
  if grep -q "php_strtolower" "$DIR/imagick.c" 2>/dev/null; then
    sed -i.bak 's/php_strtolower(\([^,]*\), \([^)]*\))/zend_str_tolower_copy(\1, \1, \2)/g' "$DIR/imagick.c" || true
    # fallback: define compat macro at top if sed pattern didn't match
    if grep -q "php_strtolower" "$DIR/imagick.c"; then
      sed -i.bak2 '1s|^|#ifndef php_strtolower\n#define php_strtolower(s,l) zend_str_tolower(s,l)\n#endif\n|' "$DIR/imagick.c"
    fi
  fi
  build_ext_both "$DIR" "--with-imagick=$DEPS"
}

build_yaz_ext() {
  log "── yaz $YAZ_VER ──"
  fetch_pecl "yaz" "$YAZ_VER"
  # --with-yaz expects the prefix containing bin/yaz-config (build_libyaz -> $DEPS)
  build_ext_both "$SRC/yaz-$YAZ_VER" "--with-yaz=$DEPS"
}

build_sysv_ext() {
  log "── sysvsem + sysvshm + sysvmsg + shmop (from PHP source) ──"
  for PHP_VER in 8.2.35 8.3.36 8.4.27 8.5.12; do
    local php_src="$SRC/php-$PHP_VER"
    local php_src_alt="$BUILD/php-$PHP_VER"
    if [ -d "$php_src_alt" ] && [ ! -d "$php_src" ]; then
      ln -sf "$php_src_alt" "$php_src"
      log "  symlinked $php_src_alt -> $php_src"
    elif [ ! -d "$php_src" ]; then
      log "  fetch PHP $PHP_VER source..."
      curl -fsSL "https://www.php.net/distributions/php-$PHP_VER.tar.gz" | tar xz -C "$SRC"
    else
      log "  skip download: php-$PHP_VER source exists"
    fi
  done

  for ext in sysvsem sysvshm sysvmsg shmop; do
    log "  ── $ext ──"
    _build_ext_one "$PHP82" "$EXT82" "$SRC/php-8.2.35/ext/$ext" ""
    _build_ext_one "$PHP83" "$EXT83" "$SRC/php-8.3.36/ext/$ext" ""
    _build_ext_one "$PHP84" "$EXT84" "$SRC/php-8.4.27/ext/$ext" ""
    _build_ext_one "$PHP85" "$EXT85" "$SRC/php-8.5.12/ext/$ext"  ""
  done
}

build_sysv_ext_86() {
  log "── sysvsem + sysvshm + sysvmsg + shmop (PHP 8.6 only) ──"
  local PHP_VER="8.6.0RC4"
  local php_src="$SRC/php-$PHP_VER"
  local php_src_alt="$BUILD/php-$PHP_VER"
  if [ -d "$php_src_alt" ] && [ ! -d "$php_src" ]; then
    ln -sf "$php_src_alt" "$php_src"
    log "  symlinked $php_src_alt -> $php_src"
  elif [ ! -d "$php_src" ]; then
    log "  fetch PHP $PHP_VER source..."
    curl -fsSL "https://downloads.php.net/~mbeccati/php-$PHP_VER.tar.gz" | tar xz -C "$SRC"
  else
    log "  skip download: php-$PHP_VER source exists"
  fi

  for ext in sysvsem sysvshm sysvmsg shmop; do
    log "  ── $ext ──"
    _build_ext_one "$PHP86" "$EXT86" "$php_src/ext/$ext" ""
  done
}

build_pgsql_ext() {
  log "── pgsql + pdo_pgsql (from PHP source) ──"
  # These are bundled extensions — need PHP source tree
  for PHP_VER in 8.2.35 8.3.36 8.4.27 8.5.12; do
    local php_src="$SRC/php-$PHP_VER"
    # PHP build trees in /tmp/php-build are also valid sources
    local php_src_alt="$BUILD/php-$PHP_VER"
    if [ -d "$php_src_alt" ] && [ ! -d "$php_src" ]; then
      ln -sf "$php_src_alt" "$php_src"
      log "  symlinked $php_src_alt -> $php_src"
    elif [ ! -d "$php_src" ]; then
      log "  fetch PHP $PHP_VER source..."
      curl -fsSL "https://www.php.net/distributions/php-$PHP_VER.tar.gz" | tar xz -C "$SRC"
    else
      log "  skip download: php-$PHP_VER source exists"
    fi
  done

  hide_mamp_ssl
  # libpq.a needs ssl/crypto for configure link test
  export LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  export LIBS="-lpq -lpgcommon -lpgport -lssl -lcrypto -lz"

  local rc=0
  _build_ext_one "$PHP82" "$EXT82" "$SRC/php-8.2.35/ext/pgsql"     "--with-pgsql=$DEPS" || rc=$?
  _build_ext_one "$PHP83" "$EXT83" "$SRC/php-8.3.36/ext/pgsql"     "--with-pgsql=$DEPS" || rc=$?
  _build_ext_one "$PHP84" "$EXT84" "$SRC/php-8.4.27/ext/pgsql"     "--with-pgsql=$DEPS" || rc=$?
  _build_ext_one "$PHP85" "$EXT85" "$SRC/php-8.5.12/ext/pgsql"      "--with-pgsql=$DEPS" || rc=$?
  _build_ext_one "$PHP82" "$EXT82" "$SRC/php-8.2.35/ext/pdo_pgsql" "--with-pdo-pgsql=$DEPS" || rc=$?
  _build_ext_one "$PHP83" "$EXT83" "$SRC/php-8.3.36/ext/pdo_pgsql" "--with-pdo-pgsql=$DEPS" || rc=$?
  _build_ext_one "$PHP84" "$EXT84" "$SRC/php-8.4.27/ext/pdo_pgsql" "--with-pdo-pgsql=$DEPS" || rc=$?
  _build_ext_one "$PHP85" "$EXT85" "$SRC/php-8.5.12/ext/pdo_pgsql"  "--with-pdo-pgsql=$DEPS" || rc=$?

  unset LDFLAGS LIBS
  restore_mamp_ssl
  return $rc
}

# ── Composite targets ──────────────────────────────────────────────────────────

build_libjbig() {
  log "── jbigkit 2.2 ──"
  fetch_tar "https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-2.2.tar.gz" "jbigkit-2.2"
  cd "$SRC/jbigkit-2.2"
  make -C libjbig CC=cc CFLAGS="-O2 -arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" libjbig.a
  install -m 644 libjbig/libjbig.a "$DEPS/lib/"
  install -m 644 libjbig/jbig.h libjbig/jbig_ar.h "$DEPS/include/"
}

build_brotli() {
  log "── brotli 1.2.1 ──"
  fetch_tar "https://github.com/google/brotli/archive/refs/tags/v1.2.1.tar.gz" "brotli-1.2.1"
  rm -rf "$SRC/brotli-1.2.1/build"
  cmake -S "$SRC/brotli-1.2.1" -B "$SRC/brotli-1.2.1/build" \
    -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DBROTLI_DISABLE_TESTS=ON
  cmake --build "$SRC/brotli-1.2.1/build" -j"$NCPU"
  cmake --install "$SRC/brotli-1.2.1/build"
}

build_highway() {
  log "── highway 1.4.0 ──"
  fetch_tar "https://github.com/google/highway/archive/refs/tags/1.4.0.tar.gz" "highway-1.4.0"
  rm -rf "$SRC/highway-1.4.0/build"
  cmake -S "$SRC/highway-1.4.0" -B "$SRC/highway-1.4.0/build" \
    -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF \
    -DHWY_ENABLE_CONTRIB=OFF
  cmake --build "$SRC/highway-1.4.0/build" -j"$NCPU"
  cmake --install "$SRC/highway-1.4.0/build"
}

build_libjxl() {
  log "── libjxl 0.12.0 ──"
  fetch_tar "https://github.com/libjxl/libjxl/archive/refs/tags/v0.12.0.tar.gz" "libjxl-0.12.0"
  rm -rf "$SRC/libjxl-0.12.0/build"
  local SKCMS_COMMIT=96d9171c94b937a1b5f0293de7309ac16311b722
  mkdir -p "$SRC/libjxl-0.12.0/third_party/skcms"
  if [ ! -f "$SRC/libjxl-0.12.0/third_party/skcms/skcms.cc" ]; then
    curl -fsSL "https://skia.googlesource.com/skcms/+archive/${SKCMS_COMMIT}.tar.gz" \
      | tar xz -C "$SRC/libjxl-0.12.0/third_party/skcms"
  fi
  cmake -S "$SRC/libjxl-0.12.0" -B "$SRC/libjxl-0.12.0/build" \
    -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$DEPS;$MAMPLIB" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
    -DJPEGXL_ENABLE_SKCMS=ON \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    -DJPEGXL_BUNDLE_LIBPNG=OFF \
    -DPNG_PNG_INCLUDE_DIR="$DEPS/include" -DPNG_LIBRARY="$DEPS/lib/libpng.a"
  cmake --build "$SRC/libjxl-0.12.0/build" -j"$NCPU"
  cmake --install "$SRC/libjxl-0.12.0/build"
}

build_djvulibre() {
  log "── djvulibre 3.5.30 ──"
  fetch_tar "https://download.sourceforge.net/djvu/DjVuLibre/3.5.30/djvulibre-3.5.30.tar.gz" "djvulibre-3.5.30"
  cd "$SRC/djvulibre-3.5.30"
  CPPFLAGS="-I$DEPS/include -I$MAMPLIB/include" \
  LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib" \
  ./configure --prefix="$DEPS" --disable-shared --enable-static \
    --without-x --disable-desktopfiles
  make -j"$NCPU"
  make install
}

build_all_deps() {
  try_build libyaml       build_libyaml
  try_build libssh2       build_libssh2
  try_build libmcrypt     build_libmcrypt
  try_build libmemcached  build_libmemcached
  try_build libpq         build_libpq
  try_build libjpeg       build_libjpeg
  try_build libpng        build_libpng
  try_build libtiff       build_libtiff
  try_build libwebp       build_libwebp
  try_build libjbig       build_libjbig
  try_build brotli        build_brotli
  try_build highway       build_highway
  try_build libjxl        build_libjxl
  try_build djvulibre     build_djvulibre
  try_build freetype      build_freetype
  try_build imagemagick   build_imagemagick
  try_build libyaz        build_libyaz
}

build_all_ext() {
  # igbinary first — redis/memcached depend on its headers
  try_build igbinary       build_igbinary
  try_build apcu           build_apcu
  try_build oauth          build_oauth
  try_build uploadprogress build_uploadprogress
  try_build xdebug         build_xdebug
  try_build redis          build_redis
  try_build yaml           build_yaml_ext
  try_build ssh2           build_ssh2_ext
  try_build mcrypt         build_mcrypt_ext
  try_build memcached      build_memcached_ext
  try_build imagick        build_imagick_ext
  try_build yaz            build_yaz_ext
  try_build sysv           build_sysv_ext
  try_build pgsql          build_pgsql_ext
}

# Build all extensions for PHP 8.5 only (C deps already built)
build_igbinary_85() {
  log "── igbinary $IGBINARY_VER (PHP 8.5 only) ──"
  fetch_pecl "igbinary" "$IGBINARY_VER"
  build_ext_85only "$SRC/igbinary-$IGBINARY_VER" || return 1
  local igbinary_h="$SRC/igbinary-$IGBINARY_VER/src/php7/igbinary.h"
  local inc="$PHP85/include/php/ext/igbinary"
  mkdir -p "$inc"
  cp "$igbinary_h" "$inc/igbinary.h"
  log "  igbinary.h installed to PHP 8.5 include dir"
}

build_mcrypt_ext_85() {
  log "── mcrypt $MCRYPT_VER (PHP 8.5 only) ──"
  fetch_pecl "mcrypt" "$MCRYPT_VER"
  local DIR="$SRC/mcrypt-$MCRYPT_VER"
  local rand_h="$PHP85/include/php/ext/standard/php_rand.h"
  if [ ! -f "$rand_h" ]; then
    printf '#pragma once\n#include "ext/random/php_random.h"\n#ifndef php_rand\n#define php_rand() rand()\n#endif\n' > "$rand_h"
  fi
  build_ext_85only "$DIR" "--with-mcrypt=$DEPS"
}

build_pgsql_ext_85() {
  log "── pgsql + pdo_pgsql (PHP 8.5 only) ──"
  local php_src="$SRC/php-8.5.12"
  local php_src_alt="$BUILD/php-8.5.12"
  if [ -d "$php_src_alt" ] && [ ! -d "$php_src" ]; then
    ln -sf "$php_src_alt" "$php_src"
  elif [ ! -d "$php_src" ]; then
    log "  fetch PHP 8.5.12 source..."
    curl -fsSL "https://www.php.net/distributions/php-8.5.12.tar.gz" | tar xz -C "$SRC"
  fi
  hide_mamp_ssl
  export LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  export LIBS="-lpq -lpgcommon -lpgport -lssl -lcrypto -lz"
  local rc=0
  _build_ext_one "$PHP85" "$EXT85" "$php_src/ext/pgsql"     "--with-pgsql=$DEPS" || rc=$?
  _build_ext_one "$PHP85" "$EXT85" "$php_src/ext/pdo_pgsql" "--with-pdo-pgsql=$DEPS" || rc=$?
  unset LDFLAGS LIBS
  restore_mamp_ssl
  return $rc
}

build_ssh2_85() {
  log "── ssh2 $SSH2_VER (PHP 8.5 only) ──"
  fetch_pecl "ssh2" "$SSH2_VER"
  hide_mamp_ssl
  export LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  export LIBS="-lssl -lcrypto"
  local rc=0
  build_ext_85only "$SRC/ssh2-$SSH2_VER" "--with-ssh2=$DEPS" || rc=$?
  unset LDFLAGS LIBS
  restore_mamp_ssl
  return $rc
}

_build_apcu_85()           { fetch_pecl "apcu" "$APCU_VER";                   build_ext_85only "$SRC/apcu-$APCU_VER"; }
_build_oauth_85() {
  _build_oauth_for "$OAUTH_VER85" build_ext_85only
}
_build_uploadprogress_85() { fetch_pecl "uploadprogress" "$UPLOADPROGRESS_VER"; build_ext_85only "$SRC/uploadprogress-$UPLOADPROGRESS_VER"; }
_build_xdebug_85()         { fetch_pecl "xdebug" "$XDEBUG_VER85"; ZLIB_CFLAGS="-I$MAMPLIB/include" ZLIB_LIBS="-L$MAMPLIB/lib -lz" CPPFLAGS="-I$MAMPLIB/include" LDFLAGS="-L$MAMPLIB/lib" build_ext_85only "$SRC/xdebug-$XDEBUG_VER85"; }
_build_redis_85()          { fetch_pecl "redis" "$REDIS_VER";                 build_ext_85only "$SRC/redis-$REDIS_VER" "--enable-redis-igbinary"; }
_build_yaml_85()           { fetch_pecl "yaml" "$YAML_VER";                   build_ext_85only "$SRC/yaml-$YAML_VER" "--with-yaml=$DEPS"; }
_build_memcached_85()      { fetch_pecl "memcached" "$MEMCACHED_VER85";       build_ext_85only "$SRC/memcached-$MEMCACHED_VER85" "--with-libmemcached-dir=$DEPS --with-zlib-dir=$MAMPLIB --enable-memcached-igbinary --enable-memcached-json --disable-memcached-sasl"; }
_build_imagick_85() {
  fetch_pecl "imagick" "$IMAGICK_VER"
  local DIR
  DIR=$(workcopy "$SRC/imagick-$IMAGICK_VER") || return 1
  if grep -q "php_strtolower" "$DIR/imagick.c" 2>/dev/null; then
    sed -i.bak 's/php_strtolower(\([^,]*\), \([^)]*\))/zend_str_tolower_copy(\1, \1, \2)/g' "$DIR/imagick.c" || true
    if grep -q "php_strtolower" "$DIR/imagick.c"; then
      sed -i.bak2 '1s|^|#ifndef php_strtolower\n#define php_strtolower(s,l) zend_str_tolower(s,l)\n#endif\n|' "$DIR/imagick.c"
    fi
  fi
  build_ext_85only "$DIR" "--with-imagick=$DEPS"
}

build_all_ext_85only() {
  # igbinary first — redis/memcached depend on its headers
  try_build igbinary       build_igbinary_85
  try_build apcu           _build_apcu_85
  try_build oauth          _build_oauth_85
  try_build uploadprogress _build_uploadprogress_85
  try_build xdebug         _build_xdebug_85
  try_build redis          _build_redis_85
  try_build yaml           _build_yaml_85
  try_build ssh2           build_ssh2_85
  try_build mcrypt         build_mcrypt_ext_85
  try_build memcached      _build_memcached_85
  try_build imagick        _build_imagick_85
  try_build pgsql          build_pgsql_ext_85
}

# ── PHP 8.6 ONLY extensions ───────────────────────────────────────────────────
# Run these AFTER building PHP 8.6 via build-php-mamp.sh.
# Usage: ./build-mamp-ext.sh ext86

# redis/memcached are built with the igbinary serializer (8.6). The header is
# not enough: the module itself must exist, or PHP cannot resolve igbinary_* at
# load time (configure-mamp-ini.py only enables .so files that exist).
igbinary_ready_86() {
  [ -f "$PHP86/include/php/ext/igbinary/igbinary.h" ] && [ -f "$EXT86/igbinary.so" ]
}

IGBINARY_FAILED_86=0
ensure_igbinary_86() {
  igbinary_ready_86 && return 0
  [ "$IGBINARY_FAILED_86" -eq 0 ] || return 1
  log "  igbinary missing — building it first"
  if ! build_igbinary_86 || ! igbinary_ready_86; then
    IGBINARY_FAILED_86=1
    return 1
  fi
}

build_igbinary_86() {
  log "── igbinary $IGBINARY_VER (PHP 8.6 only) ──"
  fetch_pecl "igbinary" "$IGBINARY_VER"
  local DIR
  DIR=$(workcopy "$SRC/igbinary-$IGBINARY_VER") || return 1
python3 - "$DIR/src/php7/igbinary.c" <<'PYPATCH' || return 1
import sys
p = sys.argv[1]
s = open(p).read()
repl = [
    ("const char* user_func_name;", "zend_string *user_func_name;"),
    ("(user_func_name == NULL) || (user_func_name[0] == '\\0')",
     "(user_func_name == NULL) || (ZSTR_LEN(user_func_name) == 0)"),
    ("ZVAL_STRING(&user_func, user_func_name);",
     "ZVAL_STR_COPY(&user_func, user_func_name);"),
    ('"Function %s() hasn\'t defined the class it was called for", PG(unserialize_callback_func)',
     '"Function %s() hasn\'t defined the class it was called for", ZSTR_VAL(user_func_name)'),
]
for old, new in repl:
    if old not in s:
        sys.exit("igbinary 8.6 patch anchor missing: " + old[:60])
    s = s.replace(old, new, 1)
for fn in ("16", "32", "64"):
    old = "zend_always_inline static int igbinary_serialize%s(" % fn
    if old in s:
        s = s.replace(old, "zend_always_inline static int __attribute__((unused)) igbinary_serialize%s(" % fn)
open(p, "w").write(s)
PYPATCH
  build_ext_86only "$DIR" || return 1
  local igbinary_h="$DIR/src/php7/igbinary.h"
  local inc="$PHP86/include/php/ext/igbinary"
  mkdir -p "$inc"
  cp "$igbinary_h" "$inc/igbinary.h"
  log "  igbinary.h installed to PHP 8.6 include dir"
}

build_mcrypt_ext_86() {
  log "── mcrypt $MCRYPT_VER (PHP 8.6 only) ──"
  fetch_pecl "mcrypt" "$MCRYPT_VER"
  local DIR
  DIR=$(workcopy "$SRC/mcrypt-$MCRYPT_VER") || return 1
  # PHP 8.6 changed the stream-filter vtable; mcrypt_filter.c no longer compiles.
  # Drop it and its registrations — mcrypt_encrypt/decrypt remain.
  sed -i.bak 's/mcrypt.c mcrypt_filter.c/mcrypt.c/' "$DIR/config.m4"
  sed -i.bak -e '/php_mcrypt_filter\.h/d' -e '/php_mcrypt_filter_factory/d' \
    -e '/php_stream_filter_register_factory/d' -e '/php_stream_filter_unregister_factory/d' \
    -e '/mcrypt_filter support/d' "$DIR/mcrypt.c"
  local rand_h="$PHP86/include/php/ext/standard/php_rand.h"
  if [ ! -f "$rand_h" ]; then
    printf '#pragma once\n#include "ext/random/php_random.h"\n#ifndef php_rand\n#define php_rand() rand()\n#endif\n' > "$rand_h"
  fi
  build_ext_86only "$DIR" "--with-mcrypt=$DEPS"
}

build_pgsql_ext_86() {
  log "── pgsql + pdo_pgsql (PHP 8.6 only) ──"
  local php_src="$SRC/php-8.6.0RC4"
  local php_src_alt="$BUILD/php-8.6.0RC4"
  if [ -d "$php_src_alt" ] && [ ! -d "$php_src" ]; then
    ln -sf "$php_src_alt" "$php_src"
  elif [ ! -d "$php_src" ]; then
    log "  fetch PHP 8.6.0RC4 source..."
    curl -fsSL "https://downloads.php.net/~mbeccati/php-8.6.0RC4.tar.gz" | tar xz -C "$SRC"
  fi
  hide_mamp_ssl
  export LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  export LIBS="-lpq -lpgcommon -lpgport -lssl -lcrypto -lz"
  local rc=0
  _build_ext_one "$PHP86" "$EXT86" "$php_src/ext/pgsql"     "--with-pgsql=$DEPS" || rc=$?
  _build_ext_one "$PHP86" "$EXT86" "$php_src/ext/pdo_pgsql" "--with-pdo-pgsql=$DEPS" || rc=$?
  unset LDFLAGS LIBS
  restore_mamp_ssl
  return $rc
}

build_ssh2_86() {
  log "── ssh2 $SSH2_VER (PHP 8.6 only) ──"
  fetch_pecl "ssh2" "$SSH2_VER"
  local DIR
  DIR=$(workcopy "$SRC/ssh2-$SSH2_VER") || return 1
  # PHP 8.6 removed zval_is_true()/zval_dtor(); upstream ssh2 1.5.0 still calls them.
  sed -i.bak -E 's/zval_is_true\(/zend_is_true(/g; s/zval_dtor\(/zval_ptr_dtor(/g' \
    "$DIR"/*.c
  hide_mamp_ssl
  export LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  export LIBS="-lssl -lcrypto"
  local rc=0
  build_ext_86only "$DIR" "--with-ssh2=$DEPS" || rc=$?
  unset LDFLAGS LIBS
  restore_mamp_ssl
  return $rc
}

build_apcu_86() {
  log "── apcu $APCU_VER (PHP 8.6 only) ──"
  fetch_pecl "apcu" "$APCU_VER"
  local DIR
  DIR=$(workcopy "$SRC/apcu-$APCU_VER") || return 1
  # php_verror() lost its docref parameter in PHP 8.6.
  sed -i.bak 's/php_verror(NULL, "", verbosity, format, args)/php_verror(NULL, verbosity, format, args)/' \
    "$DIR/apc.c"
  build_ext_86only "$DIR"
}
build_oauth_86() {
  log "── oauth $OAUTH_VER85 (PHP 8.6 only) ──"
  _build_oauth_for "$OAUTH_VER85" build_ext_86only
}
_build_uploadprogress_86() { fetch_pecl "uploadprogress" "$UPLOADPROGRESS_VER"; build_ext_86only "$SRC/uploadprogress-$UPLOADPROGRESS_VER"; }
build_xdebug_86() {
  log "── xdebug $XDEBUG_VER86 (PHP 8.6 only) ──"
  # Alpha only ships from xdebug.org; PECL tops out at 3.5.3. It already
  # accepts PHP 8.6 (< 8.7) and carries the 80600 API fixes, so no patching.
  fetch_tar "https://xdebug.org/files/xdebug-$XDEBUG_VER86.tgz" "xdebug-$XDEBUG_VER86"
  ZLIB_CFLAGS="-I$MAMPLIB/include" ZLIB_LIBS="-L$MAMPLIB/lib -lz" \
    CPPFLAGS="-I$MAMPLIB/include" LDFLAGS="-L$MAMPLIB/lib" \
    build_ext_86only "$SRC/xdebug-$XDEBUG_VER86"
}
build_redis_86() {
  log "── redis $REDIS_VER (PHP 8.6 only) ──"
  fetch_pecl "redis" "$REDIS_VER"
  local igb_flag="--enable-redis-igbinary"
  if ! ensure_igbinary_86; then
    warn "  igbinary unavailable — building redis without the igbinary serializer"
    igb_flag=""
  fi
  local DIR
  DIR=$(workcopy "$SRC/redis-$REDIS_VER") || return 1
  # Removed PHP 8.6 macros are supplied by php86-compat.h (force-included).
  # Clean up double invocations left by older sed-based attempts.
  sed -i.bak -E 's/zend_wrong_param_count\(\)\(\)/zend_wrong_param_count()/g' "$DIR"/*.c
  # PHP 8.6 session handlers take zend_string* (save_path/key/val).
  sed -i.bak -E 's/strlen\(save_path\)/ZSTR_LEN(save_path)/g; s/save_path\[i\]/ZSTR_VAL(save_path)[i]/g; s/save_path\[j\]/ZSTR_VAL(save_path)[j]/g; s/estrndup\(save_path\+i/estrndup(ZSTR_VAL(save_path)+i/g; s/php_url_parse_ex\(save_path\+i/php_url_parse_ex(ZSTR_VAL(save_path)+i/g; s/redis_strncmp\(save_path\+i/redis_strncmp(ZSTR_VAL(save_path)+i/g; s/estrdup\(save_path\)/estrdup(ZSTR_VAL(save_path))/g' \
    "$DIR/redis_session.c"
  # igbinary builds on 8.6 now (see build_igbinary_86), so enable the serializer
  # to match the 8.2-8.5 builds; igbinary.h is installed before this runs.
  build_ext_86only "$DIR" $igb_flag
}
_build_yaml_86()           { fetch_pecl "yaml" "$YAML_VER";                   build_ext_86only "$SRC/yaml-$YAML_VER" "--with-yaml=$DEPS"; }
_build_memcached_86() {
  log "── memcached $MEMCACHED_VER85 (PHP 8.6 only) ──"
  fetch_pecl "memcached" "$MEMCACHED_VER85"
  local igb_flag="--enable-memcached-igbinary"
  if ! ensure_igbinary_86; then
    warn "  igbinary unavailable — building memcached without the igbinary serializer"
    igb_flag=""
  fi
  local DIR
  DIR=$(workcopy "$SRC/memcached-$MEMCACHED_VER85") || return 1
  # PHP 8.6's PS_OPEN_FUNC passes save_path as zend_string*; this extension
  # still passed it to strstr/memcached_servers_parse (const char*) and to a
  # %s format, so every parsed path started inside the zend_string header.
python3 - "$DIR/php_memcached_session.c" <<'PYPATCH' || return 1
import sys
p = sys.argv[1]
s = open(p).read()
repl = [
    ("PS_OPEN_FUNC(memcached)\n{\n\tmemcached_st *memc   = NULL;",
     "PS_OPEN_FUNC(memcached)\n{\n\tmemcached_st *memc   = NULL;\n\tconst char *save_path_str = ZSTR_VAL(save_path);"),
    ('strstr(save_path, "PERSISTENT=")', 'strstr(save_path_str, "PERSISTENT=")'),
    ("memcached_servers_parse(save_path)", "memcached_servers_parse(save_path_str)"),
    ('"memc-session:%s", save_path', '"memc-session:%s", save_path_str'),
]
for old, new in repl:
    if old not in s:
        sys.exit("memcached 8.6 patch anchor missing: " + old[:60])
    s = s.replace(old, new, 1)
open(p, "w").write(s)
PYPATCH
  build_ext_86only "$DIR" "--with-libmemcached-dir=$DEPS --with-zlib-dir=$MAMPLIB $igb_flag --enable-memcached-json --disable-memcached-sasl"
}
_build_imagick_86() {
  fetch_pecl "imagick" "$IMAGICK_VER"
  local DIR
  DIR=$(workcopy "$SRC/imagick-$IMAGICK_VER") || return 1
  if grep -q "php_strtolower" "$DIR/imagick.c" 2>/dev/null; then
    sed -i.bak 's/php_strtolower(\([^,]*\), \([^)]*\))/zend_str_tolower_copy(\1, \1, \2)/g' "$DIR/imagick.c" || true
    if grep -q "php_strtolower" "$DIR/imagick.c"; then
      sed -i.bak2 '1s|^|#ifndef php_strtolower\n#define php_strtolower(s,l) zend_str_tolower(s,l)\n#endif\n|' "$DIR/imagick.c"
    fi
  fi
  build_ext_86only "$DIR" "--with-imagick=$DEPS"
}

build_all_ext_86only() {
  # igbinary first — redis/memcached depend on its headers
  ensure_igbinary_86 || warn "igbinary FAILED — redis/memcached will build without the igbinary serializer"
  try_build apcu           build_apcu_86
  try_build oauth          build_oauth_86
  try_build uploadprogress _build_uploadprogress_86
  try_build xdebug         build_xdebug_86
  try_build redis          build_redis_86
  try_build yaml           _build_yaml_86
  try_build sysv           build_sysv_ext_86
  try_build ssh2           build_ssh2_86
  try_build mcrypt         build_mcrypt_ext_86
  try_build memcached      _build_memcached_86
  try_build imagick        _build_imagick_86
  try_build pgsql          build_pgsql_ext_86
}

case "$TARGET" in
  # C deps
  libyaml)      build_libyaml ;;
  libssh2)      build_libssh2 ;;
  libmcrypt)    build_libmcrypt ;;
  libmemcached) build_libmemcached ;;
  libpq)        build_libpq ;;
  libjpeg)      build_libjpeg ;;
  libpng)       build_libpng ;;
  libtiff)      build_libtiff ;;
  libwebp)      build_libwebp ;;
  libjbig)      build_libjbig ;;
  brotli)       build_brotli ;;
  highway)      build_highway ;;
  libjxl)       build_libjxl ;;
  djvulibre)    build_djvulibre ;;
  freetype)     build_freetype ;;
  imagemagick)  build_imagemagick ;;
  libyaz)       build_libyaz ;;
  deps)         build_all_deps ;;

  # PHP extensions
  apcu)           build_apcu ;;
  igbinary)       build_igbinary ;;
  oauth)          build_oauth ;;
  redis)          build_redis ;;
  uploadprogress) build_uploadprogress ;;
  xdebug)         build_xdebug ;;
  yaml)           build_yaml_ext ;;
  ssh2)           build_ssh2_ext ;;
  ssh286)         build_ssh2_86 ;;
  mcrypt)         build_mcrypt_ext ;;
  mcrypt86)       build_mcrypt_ext_86 ;;
  apcu86)         build_apcu_86 ;;
  yaml86)         _build_yaml_86 ;;
  igbinary86)     build_igbinary_86 ;;
  uploadprogress86) _build_uploadprogress_86 ;;
  memcached86)    _build_memcached_86 ;;
  imagick86)      _build_imagick_86 ;;
  oauth86)        build_oauth_86 ;;
  redis86)        build_redis_86 ;;
  xdebug86)       build_xdebug_86 ;;
  memcached)      build_memcached_ext ;;
  imagick)        build_imagick_ext ;;
  yaz)            build_yaz_ext ;;
  sysv)           build_sysv_ext ;;
  sysv86)         build_sysv_ext_86 ;;
  pgsql)          build_pgsql_ext ;;
  ext)            build_all_ext ;;
  ext85)          build_all_ext_85only ;;
  oauth85)        _build_oauth_85 ;;
  ext86)          build_all_ext_86only ;;

  all)
    log "=== Phase 1: C dependencies ==="
    build_all_deps
    log "=== Phase 2: PHP extensions ==="
    build_all_ext
    ;;
  *)
    err "Unknown target: $TARGET"
    echo "Usage: $0 [all|deps|ext|ext85|ext86|libyaml|libssh2|libmcrypt|libmemcached|libpq|libjpeg|libpng|libtiff|libwebp|freetype|imagemagick|libyaz|apcu|igbinary|oauth|redis|uploadprogress|xdebug|yaml|ssh2|mcrypt|memcached|imagick|yaz|sysv|sysv86|pgsql]"
    exit 1 ;;
esac

log "=== DONE: $TARGET ==="
