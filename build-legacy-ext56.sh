#!/bin/bash
# Build PECL extensions for the legacy PHP 5.6 build.
# Uses the shared static deps in $BUILD/ext-deps.
# Usage: bash build-legacy-ext56.sh [extension ...]

set -euo pipefail

MAMP=/Applications/MAMP/Library
MAMPLIB=$MAMP/lib
BUILD="/tmp/php-build-${USER:-mamp}"
DEPS="$BUILD/ext-deps"
SRC="$BUILD/ext-src"
PHP56="/Applications/MAMP/bin/php/php5.6.40"
EXT56="$PHP56/lib/php/extensions/no-debug-non-zts-20131226"
# Native-only: arm64 on Apple Silicon, x86_64 on Intel (ignores Rosetta process arch).
source "$(cd "$(dirname "$0")" && pwd)/lib-arch.sh"
DEPLOY="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOY"
NCPU=$(sysctl -n hw.ncpu)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export PATH="$DEPS/bin:/opt/local/bin:$MAMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOY -std=gnu89"
export CXXFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOY -std=gnu++98"
export LDFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOY -L$DEPS/lib -L$MAMPLIB"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"

APCU_VER=4.0.11
IGBINARY_VER=2.0.8
IMAGICK_VER=3.4.4
MCRYPT_VER=1.0.9
MEMCACHED_VER=2.2.0
OAUTH_VER=1.2.3
REDIS_VER=4.3.0
UPLOADPROGRESS_VER=1.0.3
YAML_VER=1.3.2
XDEBUG_VER=2.5.5
SSH2_VER=0.13

mkdir -p "$SRC"
log() { echo "==> $*"; }

fetch_pecl() {
  local pkg=$1 ver=$2
  [ -d "$SRC/${pkg}-${ver}" ] && { log "skip ${pkg}-${ver}"; return; }
  log "fetch ${pkg}-${ver}"
  curl -fsSL "https://pecl.php.net/get/${pkg}-${ver}.tgz" | tar xz -C "$SRC"
}

_build_one() {
  local srcdir=$1 args="${2:-}"
  log "  build $(basename "$srcdir")"
  cd "$srcdir"
  "$PHP56/bin/phpize" --clean >/dev/null 2>&1 || true
  "$PHP56/bin/phpize" >/dev/null
  local libs_arg=()
  [ -n "${BUILD_LIBS:-}" ] && libs_arg=("LIBS=$BUILD_LIBS")
  env CPPFLAGS="${BUILD_CPPFLAGS:--I$MAMP/include -I$DEPS/include}" ${libs_arg[@]+"${libs_arg[@]}"} \
    ./configure --with-php-config="$PHP56/bin/php-config" $args >/dev/null
  if [ -f Makefile ] && [[ "$(basename "$srcdir")" == imagick-* ]]; then
    local IMAGICK_DEPS="-Wl,-force_load,$DEPS/lib/libMagickWand-7.Q16HDRI.a -Wl,-force_load,$DEPS/lib/libMagickCore-7.Q16HDRI.a $DEPS/lib/libjbig.a $DEPS/lib/libtiff.a $DEPS/lib/libfreetype.a $DEPS/lib/libjxl.a $DEPS/lib/libhwy.a $DEPS/lib/libbrotlienc.a $DEPS/lib/libbrotlidec.a $DEPS/lib/libbrotlicommon.a $DEPS/lib/libjxl_cms.a $DEPS/lib/libjxl_threads.a $DEPS/lib/libpng16.a $DEPS/lib/libdjvulibre.a $DEPS/lib/libjpeg.a $DEPS/lib/libwebpmux.a $DEPS/lib/libwebpdemux.a $DEPS/lib/libwebp.a $DEPS/lib/libsharpyuv.a -L$MAMPLIB -llzma -lbz2 -lz -lzip -lm -lpthread -framework CoreFoundation"
    sed -i.bak -E "s|^IMAGICK_SHARED_LIBADD = .*|IMAGICK_SHARED_LIBADD = -Wl,-rpath,$DEPS/lib -L$DEPS/lib $IMAGICK_DEPS|" Makefile
  fi
  if [ -f libtool ]; then
    # PHP 5.6's generated libtool may use "" or the flat_namespace default.
    # PHP 5.6 emits "" or the flat_namespace default depending on the SDK;
    # replace whatever value is there.
    sed -i.bak -E 's|^allow_undefined_flag=.*$|allow_undefined_flag="-Wl,-undefined,dynamic_lookup"|' libtool
    if ! grep -q 'allow_undefined_flag="-Wl,-undefined,dynamic_lookup"' libtool; then
      echo "ERROR: could not patch libtool for dynamic_lookup (build would mis-link)" >&2
      return 1
    fi
  fi
  # memcached: link the split-out hashkit library (see lib-arch.sh).
  patch_hashkit_makefile "$srcdir" || return 1
  make -j"$NCPU" >/dev/null
  # Normalize, install, and re-sign only the modules just built; the extension
  # directory also holds prebuilt MAMP modules that must stay untouched.
  install_modules "$EXT56/" || return 1
}

build_apcu() {
  fetch_pecl apcu "$APCU_VER"
  # shared ext-src may carry the 8.6 four-argument php_verror patch
  local DIR
  DIR=$(workcopy "$SRC/apcu-$APCU_VER") || return 1
  sed -i.bak 's/php_verror(NULL, verbosity, format, args)/php_verror(NULL, "", verbosity, format, args)/' \
    "$DIR/apc.c"
  _build_one "$DIR"
}

build_redis() {
  fetch_pecl redis "$REDIS_VER"
  # ext-src/redis may carry 8.6 zend_string session patches; 5.6 uses char*.
  local DIR
  DIR=$(workcopy "$SRC/redis-$REDIS_VER") || return 1
  sed -i.bak -E 's/ZSTR_VAL\(save_path\)/save_path/g; s/ZSTR_LEN\(save_path\)/strlen(save_path)/g' \
    "$DIR/redis_session.c"
  _build_one "$DIR" "--enable-redis-igbinary"
}

build_oauth() {
  fetch_pecl oauth "$OAUTH_VER"
  local DIR
  DIR=$(workcopy "$SRC/oauth-$OAUTH_VER") || return 1
  sed -i.bak 's|ext/standard/php_smart_string.h|ext/standard/php_smart_str.h|' \
    "$DIR/php_oauth.h"
  BUILD_CPPFLAGS="-I$MAMP/include -I$DEPS/include" \
    _build_one "$DIR"
}

build_module() {
  local name=$1 ver=$2 args="${3:-}"
  fetch_pecl "$name" "$ver"
  _build_one "$SRC/$name-$ver" "$args"
}

build_igbinary() {
  build_module igbinary "$IGBINARY_VER"
  mkdir -p "$PHP56/include/php/ext/igbinary"
  # PHP 5.6 uses the php5 header (TSRMLS_DC args, zval** unserialize);
  # the php7 header breaks redis' igbinary serializer on 5.6.
  cp "$SRC/igbinary-$IGBINARY_VER/src/php5/igbinary.h" "$PHP56/include/php/ext/igbinary/"
}

build_sysv() {
  local src="$BUILD/legacy-src/php-src-backports-PHP-5.6-security-backports-openssl11"
  [ -d "$src" ] || { log "missing 5.6 source tree"; return 1; }
  for ext in sysvmsg sysvshm sysvsem shmop; do
    _build_one "$src/ext/$ext"
  done
}

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(igbinary apcu imagick memcached oauth redis uploadprogress yaml xdebug)

for t in "${TARGETS[@]}"; do
  case "$t" in
    igbinary)       build_igbinary ;;
    apcu)           build_apcu ;;
    imagick)        build_module imagick "$IMAGICK_VER" "--with-imagick=$DEPS" ;;
    memcached)      build_module memcached "$MEMCACHED_VER" "--with-libmemcached-dir=$DEPS --with-zlib-dir=$MAMP --enable-memcached-igbinary --enable-memcached-json --disable-memcached-sasl" ;;
    mcrypt)         build_module mcrypt "$MCRYPT_VER" "--with-mcrypt=$DEPS" ;;
    oauth)          build_oauth ;;
    redis)          build_redis ;;
    uploadprogress) build_module uploadprogress "$UPLOADPROGRESS_VER" ;;
    yaml)           build_module yaml "$YAML_VER" "--with-yaml=$DEPS" ;;
    xdebug)         build_module xdebug "$XDEBUG_VER" ;;
    ssh2)           BUILD_LIBS="-Wl,-force_load,$MAMP/lib/libssl.a -Wl,-force_load,$MAMP/lib/libcrypto.a" build_module ssh2 "$SSH2_VER" "--with-ssh2=$DEPS" ;;
    sysv)           build_sysv ;;
    *) echo "Unknown extension: $t"; exit 1 ;;
  esac
done

log "DONE"
