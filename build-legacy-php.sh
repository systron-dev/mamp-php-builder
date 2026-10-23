#!/bin/bash
# Build EOL PHP 5.6 / 7.4 from community security-backport branches.
# These branches carry accumulated CVE fixes but are NOT upstream-supported.
#
# Sources: shivammathur/php-src-backports (used by setup-php's macOS builds)
#   7.4: PHP-7.4-security-backports
#   5.6: PHP-5.6-security-backports-openssl11
# Legacy PHP cannot use OpenSSL 3, so OpenSSL 1.1.1w is built static into
# a private prefix and linked into the PHP binaries.
#
# Usage: bash build-legacy-php.sh [7.4|5.6|all]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAMP=/Applications/MAMP/Library
BUILD="/tmp/php-build-${USER:-mamp}"
LEGACY="$BUILD/legacy-deps"
SRC="$BUILD/legacy-src"
BACKUP="$BUILD/legacy-backup"
ARCH=$(uname -m)
DEPLOY="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
NCPU=$(sysctl -n hw.ncpu)
STAMP=$(date +%Y%m%d-%H%M%S)

export MACOSX_DEPLOYMENT_TARGET="$DEPLOY"
export PATH="/opt/local/bin:$MAMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOY"
export CXXFLAGS="$CFLAGS"

mkdir -p "$LEGACY" "$SRC" "$BACKUP"

log() { echo "==> $*"; }

hide_onig() {
  if [ -f "$MAMP/include/oniguruma.h" ]; then
    mv "$MAMP/include/oniguruma.h" "$MAMP/include/oniguruma.h.hidden"
  fi
}
restore_onig() {
  if [ -f "$MAMP/include/oniguruma.h.hidden" ]; then
    mv "$MAMP/include/oniguruma.h.hidden" "$MAMP/include/oniguruma.h"
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
trap "restore_ssl; restore_onig" EXIT

build_openssl() {
  local V=1.1.1w
  local DIR="$SRC/openssl-$V"
  if [ ! -d "$DIR" ]; then
    log "fetch OpenSSL $V"
    curl -fsSL "https://www.openssl.org/source/openssl-$V.tar.gz" \
      | tar xz -C "$SRC"
  fi
  cd "$DIR"
  ./Configure --prefix="$LEGACY" --openssldir="$LEGACY/openssl" \
    no-shared no-tests "darwin64-${ARCH}-cc"
  make -j"$NCPU" build_libs
  make install_sw
}

build_libxml2() {
  local V=2.9.14
  local DIR="$SRC/libxml2-$V"
  if [ ! -d "$DIR" ]; then
    log "fetch libxml2 $V"
    curl -fsSL "https://download.gnome.org/sources/libxml2/2.9/libxml2-$V.tar.xz" | tar xJ -C "$SRC"
  fi
  cd "$DIR"
  ./configure --prefix="$LEGACY" --disable-shared --enable-static \
    --without-python --without-lzma --without-iconv
  make clean >/dev/null 2>&1 || true
  make -j"$NCPU"
  make install
}

fetch_php() {
  local branch=$1 dir=$2
  if [ ! -d "$SRC/$dir" ]; then
    log "fetch $branch"
    curl -fsSL "https://github.com/shivammathur/php-src-backports/archive/refs/heads/$branch.tar.gz" \
      | tar xz -C "$SRC"
  fi
}

install_php() {
  local dir=$1 version=$2 prefix="/Applications/MAMP/bin/php/php$2"
  local extra=() std=gnu11 zlib_flag=--with-zlib tidy_flag=--with-tidy="$MAMP"
  # Sodium/Argon2 exist only in 7.4; passing them to 5.6's configure aborts.
  if [ "$version" = "7.4.33" ]; then
    extra+=(--with-sodium="$MAMP" --with-password-argon2="$MAMP")
  else
    std=gnu89
    zlib_flag=--with-zlib="$MAMP"
    extra+=(--with-icu-dir="$MAMP")
    cpp_flags="-I$LEGACY/include"
    hide_onig
    tidy_flag=--without-tidy
    extra+=(--disable-opcache)
    warn_flags="-Wno-error=incompatible-function-pointer-types -Wno-error=implicit-function-declaration -Wno-error=deprecated-non-prototype"
  fi
  # Xcode 21's clang defaults to C23, which rejects K&R definitions.
  local legacy_cflags="$CFLAGS -std=$std ${warn_flags:-}"
  local legacy_cxxflags="$CXXFLAGS -std=$([ "$std" = gnu89 ] && echo gnu++98 || echo gnu++11)"
  cd "$SRC/$dir"
  ./buildconf --force
  hide_ssl
  ./configure --prefix="$prefix" --exec-prefix="$prefix" \
    --sysconfdir="$prefix/conf" --with-config-file-path="$prefix/conf" \
    --with-openssl="$LEGACY" \
    "$zlib_flag" \
    --with-curl="$MAMP" \
    --with-libxml-dir="$LEGACY" \
    "$tidy_flag" \
    --with-gettext="$MAMP" \
    --with-iconv="$MAMP" \
    --with-ldap="$MAMP" \
    ${extra[@]+"${extra[@]}"} \
    --with-mysqli=mysqlnd \
    --with-pdo-mysql=mysqlnd \
    --enable-intl \
    --enable-mbstring \
    --enable-bcmath \
    --enable-soap \
    --enable-calendar \
    --enable-exif \
    --enable-ftp \
    --enable-sockets \
    --enable-pcntl \
    --enable-cgi \
    --disable-phpdbg \
    --without-pcre-jit \
    --without-sqlite3 \
    --without-pdo-sqlite \
    --without-xsl \
    --disable-gd \
    PKG_CONFIG_PATH="$LEGACY/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="$LEGACY/lib/pkgconfig" \
    CURL_CFLAGS="-I$MAMP/include" \
    CURL_LIBS="-L$MAMP/lib -lcurl -lnghttp2 -lldap -lz" \
    ZLIB_CFLAGS="-I$MAMP/include" \
    ZLIB_LIBS="-L$MAMP/lib -lz" \
    LIBXML_CFLAGS="-I$LEGACY/include/libxml2" \
    LIBXML_LIBS="-L$LEGACY/lib -lxml2 -lz -lpthread -liconv -lm" \
    LIBSODIUM_CFLAGS="-I$MAMP/include" \
    LIBSODIUM_LIBS="-L$MAMP/lib -lsodium" \
    ARGON2_CFLAGS="-I$MAMP/include" \
    ARGON2_LIBS="-L$MAMP/lib -largon2" \
    ICU_CFLAGS="-I$MAMP/include" \
    ICU_LIBS="-L$MAMP/lib -licui18n -licuuc -licudata -licuio" \
    CFLAGS="$legacy_cflags" CXXFLAGS="$legacy_cxxflags" \
    LIBS="-lresolv" \
    LDFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOY -L$LEGACY/lib -L$MAMP/lib -Wl,-force_load,$LEGACY/lib/libssl.a -Wl,-force_load,$LEGACY/lib/libcrypto.a" \
    "CPPFLAGS=${cpp_flags:--I$LEGACY/include -I$MAMP/include}"
  # configure picks up /opt/local through pkg-config; force MAMP libs first
  # so ICU 56 and the bundled deps win over MacPorts copies.
  sed -i.bak -E "s#^PHP_LDFLAGS = .*#PHP_LDFLAGS = -L$LEGACY/lib -L$MAMP/lib -Wl,-force_load,$LEGACY/lib/libssl.a -Wl,-force_load,$LEGACY/lib/libcrypto.a#" Makefile
  sed -i.bak -E "s#-L/opt/local[^ ]*##g; s#-Wl,-rpath,/opt/local[^ ]*##g" Makefile
  # 7.4 forces the xsl extension on when libxslt is present; MAMP's libxml2
  # hides xmlXPathValuePop/Push, so drop xsl objects and libs entirely.
  sed -i.bak -E "s#ext/xsl/[A-Za-z0-9_./-]+\.lo##g; s#-lxslt##g; s#-lexslt##g" Makefile
  make clean >/dev/null 2>&1 || true
  make -j"$NCPU"
  make install
  restore_ssl
  restore_onig

  local src_libphp
  src_libphp=$(find . -maxdepth 2 -name libphp.so | head -1)
  if [ -n "$src_libphp" ]; then
    mkdir -p "$prefix/modules"
    cp "$src_libphp" "$prefix/modules/libphp.so"
    codesign --force --sign - "$prefix/modules/libphp.so"
  fi
}

backup_existing() {
  local version=$1 dir="/Applications/MAMP/bin/php/php$1"
  [ -d "$dir" ] || return 0
  local out="$BACKUP/php$version-$STAMP.tar.gz"
  [ -f "$out" ] && return 0
  log "backup $dir -> $out"
  tar czf "$out" -C /Applications/MAMP/bin/php "php$version"
}

build_74() {
  fetch_php PHP-7.4-security-backports php-src-backports-PHP-7.4-security-backports
  backup_existing 7.4.33
  install_php php-src-backports-PHP-7.4-security-backports 7.4.33
}

build_56() {
  fetch_php PHP-5.6-security-backports-openssl11 php-src-backports-PHP-5.6-security-backports-openssl11
  backup_existing 5.6.40
  install_php php-src-backports-PHP-5.6-security-backports-openssl11 5.6.40
}

TARGET="${1:-all}"
build_openssl
build_libxml2
case "$TARGET" in
  7.4) build_74 ;;
  5.6) build_56 ;;
  all) build_74; build_56 ;;
  *) echo "Usage: $0 [7.4|5.6|all]"; exit 1 ;;
esac

log "DONE: $TARGET"
log "Backups: $BACKUP"
