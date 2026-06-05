#!/bin/bash
# Build missing PHP extensions for MAMP PHP 8.2.31, 8.3.31, 8.4.21, 8.5.6
# All deps built from source — no Homebrew dependencies
# Usage: ./build-mamp-ext.sh [target]
# Targets: all | deps | ext | <specific> (see case block at bottom)

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
MAMP=/Applications/MAMP
MAMPLIB=$MAMP/Library
PHP82=$MAMP/bin/php/php8.2.31
PHP83=$MAMP/bin/php/php8.3.31
PHP84=$MAMP/bin/php/php8.4.21
PHP85=$MAMP/bin/php/php8.5.6
EXT82=$PHP82/lib/php/extensions/no-debug-non-zts-20220829
EXT83=$PHP83/lib/php/extensions/no-debug-non-zts-20230831
EXT84=$PHP84/lib/php/extensions/no-debug-non-zts-20240924
EXT85=$PHP85/lib/php/extensions/no-debug-non-zts-20250925
BUILD="/tmp/php-build-${USER:-mamp}"
DEPS=$BUILD/ext-deps        # static libs installed here
SRC=$BUILD/ext-src          # source trees unpacked here
NCPU=$(sysctl -n hw.ncpu)
ARCH=$(uname -m)   # arm64 on Apple Silicon, x86_64 on Intel

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
OAUTH_VER=2.0.9
OAUTH_VER85=2.0.10  # 2.0.10 adds PHP 8.5 compat (zend_exception_get_default removed)
REDIS_VER=6.1.0
UPLOADPROGRESS_VER=2.0.2
XDEBUG_VER=3.4.3
XDEBUG_VER85=3.5.1  # xdebug 3.4.x requires PHP < 8.5; use 3.5.x for PHP 8.5
YAML_VER=2.2.4
SSH2_VER=1.4.1
MCRYPT_VER=1.0.7
MEMCACHED_VER=3.3.0
MEMCACHED_VER85=3.4.0  # 3.4.0 adds PHP 8.5 compat (zend_exception_get_default removed)
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
if [ -z "$MACOSX_DEPLOYMENT_TARGET" ]; then
  if [ -t 0 ]; then
    read -p "Enter target macOS version for the build (e.g. 12.0, 13.0, 14.0, 15.0) [default: 12.0]: " TARGET_VAL
    export MACOSX_DEPLOYMENT_TARGET="${TARGET_VAL:-12.0}"
  else
    export MACOSX_DEPLOYMENT_TARGET="12.0"
  fi
fi
echo "==> macOS Deployment Target: $MACOSX_DEPLOYMENT_TARGET"

export CXXFLAGS="-arch $ARCH"

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
  [ -x "$PHP82/bin/phpize" ]        || { err "Missing $PHP82/bin/phpize"; fail=1; }
  [ -x "$PHP83/bin/phpize" ]        || { err "Missing $PHP83/bin/phpize"; fail=1; }
  [ -x "$PHP84/bin/phpize" ]        || { err "Missing $PHP84/bin/phpize"; fail=1; }
  [ -x "$PHP85/bin/phpize" ]        || { err "Missing $PHP85/bin/phpize"; fail=1; }
  [ $fail -eq 0 ] || exit 1

  # Create php_smart_string.h shim for PHP 8.5
  local smart_string_h="$PHP85/include/php/ext/standard/php_smart_string.h"
  if [ -d "$(dirname "$smart_string_h")" ] && [ ! -f "$smart_string_h" ]; then
    printf '#pragma once\n#include "Zend/zend_smart_string.h"\n' > "$smart_string_h"
    log "Created php_smart_string.h shim for PHP 8.5"
  fi
}

# ── OpenSSL dylib hide/restore ─────────────────────────────────────────────────
hide_mamp_ssl() {
  [ -f "$MAMPLIB/lib/libssl.dylib" ]    && mv "$MAMPLIB/lib/libssl.dylib"    "$MAMPLIB/lib/libssl.dylib.hidden"    || true
  [ -f "$MAMPLIB/lib/libcrypto.dylib" ] && mv "$MAMPLIB/lib/libcrypto.dylib" "$MAMPLIB/lib/libcrypto.dylib.hidden" || true
}
restore_mamp_ssl() {
  [ -f "$MAMPLIB/lib/libssl.dylib.hidden" ]    && mv "$MAMPLIB/lib/libssl.dylib.hidden"    "$MAMPLIB/lib/libssl.dylib"    || true
  [ -f "$MAMPLIB/lib/libcrypto.dylib.hidden" ] && mv "$MAMPLIB/lib/libcrypto.dylib.hidden" "$MAMPLIB/lib/libcrypto.dylib" || true
}
trap restore_mamp_ssl EXIT INT TERM

# ── Download helpers ──────────────────────────────────────────────────────────
fetch_tar() {
  local url=$1 dir=$2
  if [ -d "$SRC/$dir" ]; then log "  skip download: $dir"; return; fi
  log "  fetch: $(basename $url)"
  curl -fsSL "$url" | tar xz -C "$SRC"
}

fetch_pecl() {
  local pkg=$1 ver=$2
  [ -d "$SRC/${pkg}-${ver}" ] && { log "  skip download: $pkg-$ver"; return; }
  log "  fetch PECL: $pkg-$ver"
  curl -fsSL "https://pecl.php.net/get/${pkg}-${ver}.tgz" | tar xz -C "$SRC"
}

# ── Extension build core ──────────────────────────────────────────────────────
# Builds one extension against one PHP version. Env vars LDFLAGS/LIBS/CPPFLAGS
# are forwarded to configure and make if set.
_build_ext_one() {
  local phpdir=$1 extdir=$2 srcdir=$3 configure_args="${4:-}"
  log "    → PHP $(basename $phpdir)"
  cd "$srcdir"
  "$phpdir/bin/phpize" --clean 2>/dev/null || true
  "$phpdir/bin/phpize" || return 1
  # pcre2.h lives in MAMP Library — not searched by default phpize builds
  CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I$MAMPLIB/include" \
    ./configure --with-php-config="$phpdir/bin/php-config" $configure_args || return 1
  make -j$NCPU || return 1
  if [ "$(uname)" = "Darwin" ]; then
    log "    → Code-signing modules/*.so"
    for so_file in modules/*.so; do
      if [ -f "$so_file" ]; then
        codesign --force --sign - "$so_file"
      fi
    done
  fi
  if cp modules/*.so "$extdir/" 2>/dev/null; then
    log "    ✓ copied to $extdir"
  else
    local local_dist="$(cd "$(dirname "$0")" && pwd)/dist/$(basename $phpdir)"
    mkdir -p "$local_dist"
    cp modules/*.so "$local_dist/"
    warn "    ! Permission denied writing to $extdir. Copied to $local_dist instead."
  fi
}

# Build extension for all PHP versions
build_ext_both() {
  local srcdir=$1 configure_args="${2:-}"
  _build_ext_one "$PHP82" "$EXT82" "$srcdir" "$configure_args"
  _build_ext_one "$PHP83" "$EXT83" "$srcdir" "$configure_args"
  _build_ext_one "$PHP84" "$EXT84" "$srcdir" "$configure_args"
  _build_ext_one "$PHP85" "$EXT85" "$srcdir" "$configure_args"
}

# Build extension for PHP 8.5 only
build_ext_85only() {
  local srcdir=$1 configure_args="${2:-}"
  _build_ext_one "$PHP85" "$EXT85" "$srcdir" "$configure_args"
}

# Soft-fail wrapper: log warning but don't abort the whole build
try_build() {
  local name=$1; shift
  if "$@"; then
    log "✓ $name done"
  else
    warn "✗ $name FAILED — skipping, check output above"
  fi
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
  CFLAGS="-std=gnu89 -Wno-implicit-function-declaration -Wno-implicit-int" \
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
}

build_libpq() {
  log "── PostgreSQL $PG_VER (libpq only) ──"
  local DIR="postgresql-$PG_VER"
  fetch_tar "https://ftp.postgresql.org/pub/source/v$PG_VER/postgresql-$PG_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  hide_mamp_ssl
  # Build just enough for libpq — no server, no readline
  ./configure --prefix="$DEPS" \
    --without-readline \
    --with-ssl=openssl \
    CPPFLAGS="-I$MAMPLIB/include" \
    LDFLAGS="-L$MAMPLIB/lib"
  # Unset deployment target — PG 16 uses strchrnul which requires macOS 15.4+
  # The running system is macOS 15+ so this is safe
  local saved_target="${MACOSX_DEPLOYMENT_TARGET:-}"
  export MACOSX_DEPLOYMENT_TARGET=15.4
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
  [ -n "$saved_target" ] && export MACOSX_DEPLOYMENT_TARGET="$saved_target" || true
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
    CPPFLAGS="-I$DEPS/include" \
    LDFLAGS="-L$DEPS/lib"
  make -j$NCPU && make install
}

build_imagemagick() {
  log "── ImageMagick $IMAGEMAGICK_VER ──"
  # Fetch — GitHub archive extracts to ImageMagick-VERSION
  local DIR="ImageMagick-$IMAGEMAGICK_VER"
  fetch_tar "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$IMAGEMAGICK_VER.tar.gz" "$DIR"
  cd "$SRC/$DIR"
  ./configure --prefix="$DEPS" \
    --enable-static --disable-shared \
    --disable-docs \
    --without-x \
    --without-perl \
    --without-magick-plus-plus \
    --with-jpeg="$DEPS" \
    --with-png="$DEPS" \
    --with-tiff="$DEPS" \
    --with-webp="$DEPS" \
    --with-freetype="$DEPS" \
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
    PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$MAMPLIB/lib/pkgconfig"
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
  build_ext_both "$SRC/igbinary-$IGBINARY_VER"
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

build_oauth() {
  log "── oauth $OAUTH_VER ──"
  fetch_pecl "oauth" "$OAUTH_VER"
  build_ext_both "$SRC/oauth-$OAUTH_VER"
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
  build_ext_both "$SRC/ssh2-$SSH2_VER" "--with-ssh2=$DEPS"
  unset LDFLAGS LIBS
  restore_mamp_ssl
}

build_mcrypt_ext() {
  log "── mcrypt $MCRYPT_VER ──"
  fetch_pecl "mcrypt" "$MCRYPT_VER"
  local DIR="$SRC/mcrypt-$MCRYPT_VER"
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
  local DIR="$SRC/imagick-$IMAGICK_VER"
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
  # --with-yaz expects the dir containing bin/yaz-config
  build_ext_both "$SRC/yaz-$YAZ_VER" "--with-yaz=$DEPS"
}

build_sysv_ext() {
  log "── sysvsem + sysvshm + sysvmsg + shmop (from PHP source) ──"
  for PHP_VER in 8.2.31 8.3.31 8.4.21 8.5.6; do
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
    _build_ext_one "$PHP82" "$EXT82" "$SRC/php-8.2.31/ext/$ext" ""
    _build_ext_one "$PHP83" "$EXT83" "$SRC/php-8.3.31/ext/$ext" ""
    _build_ext_one "$PHP84" "$EXT84" "$SRC/php-8.4.21/ext/$ext" ""
    _build_ext_one "$PHP85" "$EXT85" "$SRC/php-8.5.6/ext/$ext"  ""
  done
}

build_pgsql_ext() {
  log "── pgsql + pdo_pgsql (from PHP source) ──"
  # These are bundled extensions — need PHP source tree
  for PHP_VER in 8.2.31 8.3.31 8.4.21 8.5.6; do
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

  _build_ext_one "$PHP82" "$EXT82" "$SRC/php-8.2.31/ext/pgsql"     "--with-pgsql=$DEPS"
  _build_ext_one "$PHP83" "$EXT83" "$SRC/php-8.3.31/ext/pgsql"     "--with-pgsql=$DEPS"
  _build_ext_one "$PHP84" "$EXT84" "$SRC/php-8.4.21/ext/pgsql"     "--with-pgsql=$DEPS"
  _build_ext_one "$PHP85" "$EXT85" "$SRC/php-8.5.6/ext/pgsql"      "--with-pgsql=$DEPS"
  _build_ext_one "$PHP82" "$EXT82" "$SRC/php-8.2.31/ext/pdo_pgsql" "--with-pdo-pgsql=$DEPS"
  _build_ext_one "$PHP83" "$EXT83" "$SRC/php-8.3.31/ext/pdo_pgsql" "--with-pdo-pgsql=$DEPS"
  _build_ext_one "$PHP84" "$EXT84" "$SRC/php-8.4.21/ext/pdo_pgsql" "--with-pdo-pgsql=$DEPS"
  _build_ext_one "$PHP85" "$EXT85" "$SRC/php-8.5.6/ext/pdo_pgsql"  "--with-pdo-pgsql=$DEPS"

  unset LDFLAGS LIBS
  restore_mamp_ssl
}

# ── Composite targets ──────────────────────────────────────────────────────────

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
  local php_src="$SRC/php-8.5.6"
  local php_src_alt="$BUILD/php-8.5.6"
  if [ -d "$php_src_alt" ] && [ ! -d "$php_src" ]; then
    ln -sf "$php_src_alt" "$php_src"
  elif [ ! -d "$php_src" ]; then
    log "  fetch PHP 8.5.6 source..."
    curl -fsSL "https://www.php.net/distributions/php-8.5.6.tar.gz" | tar xz -C "$SRC"
  fi
  hide_mamp_ssl
  export LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  export LIBS="-lpq -lpgcommon -lpgport -lssl -lcrypto -lz"
  _build_ext_one "$PHP85" "$EXT85" "$php_src/ext/pgsql"     "--with-pgsql=$DEPS"
  _build_ext_one "$PHP85" "$EXT85" "$php_src/ext/pdo_pgsql" "--with-pdo-pgsql=$DEPS"
  unset LDFLAGS LIBS
  restore_mamp_ssl
}

build_ssh2_85() {
  log "── ssh2 $SSH2_VER (PHP 8.5 only) ──"
  fetch_pecl "ssh2" "$SSH2_VER"
  hide_mamp_ssl
  export LDFLAGS="-L$DEPS/lib -L$MAMPLIB/lib"
  export LIBS="-lssl -lcrypto"
  build_ext_85only "$SRC/ssh2-$SSH2_VER" "--with-ssh2=$DEPS"
  unset LDFLAGS LIBS
  restore_mamp_ssl
}

_build_apcu_85()           { fetch_pecl "apcu" "$APCU_VER";                   build_ext_85only "$SRC/apcu-$APCU_VER"; }
_build_oauth_85()          { fetch_pecl "oauth" "$OAUTH_VER85";               build_ext_85only "$SRC/oauth-$OAUTH_VER85"; }
_build_uploadprogress_85() { fetch_pecl "uploadprogress" "$UPLOADPROGRESS_VER"; build_ext_85only "$SRC/uploadprogress-$UPLOADPROGRESS_VER"; }
_build_xdebug_85()         { fetch_pecl "xdebug" "$XDEBUG_VER85";             build_ext_85only "$SRC/xdebug-$XDEBUG_VER85"; }
_build_redis_85()          { fetch_pecl "redis" "$REDIS_VER";                 build_ext_85only "$SRC/redis-$REDIS_VER" "--enable-redis-igbinary"; }
_build_yaml_85()           { fetch_pecl "yaml" "$YAML_VER";                   build_ext_85only "$SRC/yaml-$YAML_VER" "--with-yaml=$DEPS"; }
_build_memcached_85()      { fetch_pecl "memcached" "$MEMCACHED_VER85";       build_ext_85only "$SRC/memcached-$MEMCACHED_VER85" "--with-libmemcached-dir=$DEPS --with-zlib-dir=$MAMPLIB --enable-memcached-igbinary --enable-memcached-json --disable-memcached-sasl"; }
_build_imagick_85() {
  fetch_pecl "imagick" "$IMAGICK_VER"
  local DIR="$SRC/imagick-$IMAGICK_VER"
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

# ── Dispatch ──────────────────────────────────────────────────────────────────
TARGET="${1:-all}"
preflight

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
  mcrypt)         build_mcrypt_ext ;;
  memcached)      build_memcached_ext ;;
  imagick)        build_imagick_ext ;;
  yaz)            build_yaz_ext ;;
  sysv)           build_sysv_ext ;;
  pgsql)          build_pgsql_ext ;;
  ext)            build_all_ext ;;
  ext85)          build_all_ext_85only ;;

  all)
    log "=== Phase 1: C dependencies ==="
    build_all_deps
    log "=== Phase 2: PHP extensions ==="
    build_all_ext
    ;;
  *)
    err "Unknown target: $TARGET"
    echo "Usage: $0 [all|deps|ext|ext85|libyaml|libssh2|libmcrypt|libmemcached|libpq|libjpeg|libpng|libtiff|libwebp|freetype|imagemagick|libyaz|apcu|igbinary|oauth|redis|uploadprogress|xdebug|yaml|ssh2|mcrypt|memcached|imagick|yaz|sysv|pgsql]"
    exit 1 ;;
esac

log "=== DONE: $TARGET ==="
