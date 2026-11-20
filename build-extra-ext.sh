#!/bin/bash
# Build extra self-contained PHP extensions (ffi, dba, gmp, mongodb, amqp, protobuf)
# for MAMP PHP 8.2.36, 8.3.37, 8.4.28, 8.5.13, 8.6.0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAMP="/Applications/MAMP"
MAMPLIB="$MAMP/Library"
BUILD="/tmp/php-build-${USER:-mamp}"
DEPS="$BUILD/ext-deps"
SRC="$BUILD/ext-src"
source "$SCRIPT_DIR/lib-arch.sh"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
export PATH="/opt/local/bin:$MAMPLIB/bin:/usr/bin:/bin:/usr/sbin:/sbin"
NCPU=$(sysctl -n hw.ncpu)

mkdir -p "$DEPS" "$SRC"

log() { echo "[EXTRA] $*"; }

build_gmp_dep() {
  if [ -f "$DEPS/lib/libgmp.a" ]; then
    log "skip libgmp (already built)"
    return 0
  fi
  local V=6.3.0
  local DIR="$SRC/gmp-$V"
  if [ ! -d "$DIR" ]; then
    log "fetch gmp-$V"
    curl -fsSL "https://ftp.gnu.org/gnu/gmp/gmp-$V.tar.xz" | tar xJ -C "$SRC"
  fi
  cd "$DIR"
  CFLAGS="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2" \
    ./configure --prefix="$DEPS" --disable-shared --enable-static
  make -j"$NCPU"
  make install
}

build_rabbitmq_dep() {
  if [ -f "$DEPS/lib/librabbitmq.a" ]; then
    log "skip librabbitmq (already built)"
    return 0
  fi
  local V=0.15.0
  local DIR="$SRC/rabbitmq-c-$V"
  if [ ! -d "$DIR" ]; then
    log "fetch rabbitmq-c-$V"
    curl -fsSL "https://github.com/alanxz/rabbitmq-c/archive/refs/tags/v$V.tar.gz" | tar xz -C "$SRC"
  fi
  hide_openssl_dylibs "$MAMPLIB/lib"
  trap 'restore_openssl_dylibs "$MAMPLIB/lib"' RETURN
  rm -rf "$DIR/build-mamp" && mkdir -p "$DIR/build-mamp"
  cd "$DIR/build-mamp"
  cmake .. \
    -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_TOOLS=OFF \
    -DENABLE_SSL_SUPPORT=ON \
    -DOPENSSL_ROOT_DIR="$MAMPLIB" \
    -DOPENSSL_INCLUDE_DIR="$MAMPLIB/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$MAMPLIB/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$MAMPLIB/lib/libssl.a"
  cmake --build . -j"$NCPU"
  cmake --install .
}

fetch_pecl() {
  local name=$1 ver=$2
  if [ ! -d "$SRC/$name-$ver" ]; then
    log "fetch $name-$ver"
    curl -fsSL "https://pecl.php.net/get/$name-$ver.tgz" | tar xz -C "$SRC"
  fi
}

build_ext_for_ver() {
  local ver=$1 ext_name=$2 src_dir=$3 conf_flags=$4 extra_cflags=${5:-}
  local php_dir="$MAMP/bin/php/php$ver"
  local ext_dir
  ext_dir=$(ls -d "$php_dir/lib/php/extensions"/no-debug-non-zts-* 2>/dev/null | head -1)
  if [ -z "$ext_dir" ]; then
    log "WARN: no ext_dir for php$ver"
    return 1
  fi
  if [ -f "$ext_dir/${ext_name}.so" ]; then
    log "skip $ext_name for php$ver (already exists)"
    return 0
  fi

  local work="$BUILD/ext-work-${ext_name}-${ver}-$$"
  rm -rf "$work"
  cp -R "$src_dir" "$work"
  cd "$work"

  local cflags="-O2 -arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -I$DEPS/include -I$MAMPLIB/include $extra_cflags"
  local ldflags="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -L$DEPS/lib -L$MAMPLIB/lib"

  "$php_dir/bin/phpize" >/dev/null
  PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$MAMPLIB/lib/pkgconfig" \
    CFLAGS="$cflags" CXXFLAGS="$cflags" LDFLAGS="$ldflags" \
    ./configure --with-php-config="$php_dir/bin/php-config" $conf_flags >/dev/null
  make -j"$NCPU" >/dev/null

  local so_file="modules/${ext_name}.so"
  if [ ! -f "$so_file" ]; then
    log "ERROR: $so_file not built for php$ver"
    rm -rf "$work"
    return 1
  fi
  cp "$so_file" "$ext_dir/${ext_name}.so"
  MAMPLIB="$MAMPLIB/lib" normalize_module_links "$ext_dir/${ext_name}.so"
  rm -rf "$work"

  # Enable in php.ini and php.ini.temp if not already present
  for ini in "$php_dir/conf/php.ini" "$php_dir/conf/php.ini.temp"; do
    [ -f "$ini" ] || continue
    if ! grep -qE "^extension=${ext_name}(\.so)?$" "$ini"; then
      [ -s "$ini" ] && [ "$(tail -c1 "$ini" | wc -l)" -eq 0 ] && printf '\n' >> "$ini"
      echo "extension=${ext_name}.so" >> "$ini"
    fi
  done
  log "✓ $ext_name.so installed for php$ver"
}

build_gmp_dep
build_rabbitmq_dep
fetch_pecl mongodb 2.5.8
fetch_pecl amqp 2.2.0
fetch_pecl protobuf 5.36.2

VERSIONS=("8.2.36" "8.3.37" "8.4.28" "8.5.13" "8.6.0")
for ver in "${VERSIONS[@]}"; do
  php_src="$SRC/php-$ver"
  if [ ! -d "$php_src" ]; then
    log "fetch php-$ver source"
    curl -fsSL "https://www.php.net/distributions/php-$ver.tar.gz" | tar xz -C "$SRC"
  fi
  extra_cf=""
  [ "$ver" = "8.6.0" ] && extra_cf="-include $SCRIPT_DIR/php86-compat.h"

  build_ext_for_ver "$ver" "ffi"      "$php_src/ext/ffi"  "" "$extra_cf" || true
  build_ext_for_ver "$ver" "dba"      "$php_src/ext/dba"  "--enable-dba=shared --with-cdb --with-inifile --with-flatfile" "$extra_cf" || true
  build_ext_for_ver "$ver" "gmp"      "$php_src/ext/gmp"  "--with-gmp=$DEPS" "$extra_cf" || true
  build_ext_for_ver "$ver" "mongodb"  "$SRC/mongodb-2.5.8" "" "$extra_cf" || true
  build_ext_for_ver "$ver" "amqp"     "$SRC/amqp-2.2.0"   "--with-librabbitmq-dir=$DEPS" "$extra_cf" || true
  build_ext_for_ver "$ver" "protobuf" "$SRC/protobuf-5.36.2" "" "$extra_cf" || true
done

log "=== DONE ==="
