#!/bin/bash
# Build PHP from source for MAMP on Apple Silicon
# All deps must reside in /Applications/MAMP/Library — no Homebrew at runtime.
# PREREQUISITE: OpenSSL 3.x must be built from source and installed into
#   /Applications/MAMP/Library before running this script.
#   (MAMP ships OpenSSL 1.0.2u which is too old for PHP 8.3+)
# Usage: bash build-php-mamp.sh 8.2.31
#         bash build-php-mamp.sh 8.3.31
#         bash build-php-mamp.sh 8.4.21
#         bash build-php-mamp.sh 8.5.6
# PHP 8.5 notes: --enable-opcache removed (opcache always static); comment out
#   zend_extension=opcache.so in php.ini. Run build-mamp-ext.sh ext85 for extensions.

set -e
VERSION="$1"
ARCH=$(uname -m)   # arm64 on Apple Silicon, x86_64 on Intel
MAMP=/Applications/MAMP/Library
BUILD="/tmp/php-build-${USER:-mamp}"
SRC="${BUILD}/php-${VERSION}"
PREFIX="/Applications/MAMP/bin/php/php${VERSION}"

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"; exit 1
fi

# Verify OpenSSL 1.1+ is present in MAMP before proceeding
OSSL_VER=$(grep -r "OPENSSL_VERSION_NUMBER" "$MAMP/include/openssl/opensslv.h" 2>/dev/null | head -1)
if echo "$OSSL_VER" | grep -q "0x100"; then
  echo "ERROR: MAMP's OpenSSL is 1.0.x — too old for PHP 8.3+."
  echo "Build OpenSSL 3.x from source into $MAMP first. See PREREQS above."
  exit 1
fi

export PATH="$MAMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# All pkg-config overrides — MAMP only, no external package managers
export LIBXML_CFLAGS="-I$MAMP/include/libxml2 -I$MAMP/include"
export LIBXML_LIBS="-L$MAMP/lib -lxml2 -lz -llzma -lpthread -liconv -licui18n -licuuc -licudata -lm"
export LIBZIP_CFLAGS="-I$MAMP/include"
export LIBZIP_LIBS="-L$MAMP/lib -lzip"
export ONIG_CFLAGS="-I$MAMP/include"
export ONIG_LIBS="-L$MAMP/lib -lonig"
export PCRE2_CFLAGS="-I$MAMP/include"
export PCRE2_LIBS="-L$MAMP/lib -lpcre2-8"
export OPENSSL_CFLAGS="-I$MAMP/include"
# Use -L/-l flags so PHP_EVAL_LIBLINE can parse them (full .a paths are silently dropped)
# The libssl.dylib/libcrypto.dylib symlinks are hidden below so linker finds only .a files
export OPENSSL_LIBS="-L$MAMP/lib -lssl -lcrypto"
export ICU_CFLAGS="-I$MAMP/include"
export ICU_LIBS="-L$MAMP/lib -licui18n -licuuc -licudata -licuio"
export ZLIB_CFLAGS="-I$MAMP/include"
export ZLIB_LIBS="-L$MAMP/lib -lz"
export CURL_CFLAGS="-I$MAMP/include"
export CURL_LIBS="-L$MAMP/lib -lcurl -lnghttp2 -lldap -lz"
export WEBP_CFLAGS="-I$MAMP/include"
export WEBP_LIBS="-L$MAMP/lib -lwebp"
export FREETYPE2_CFLAGS="-I$MAMP/include/freetype2"
export FREETYPE2_LIBS="-L$MAMP/lib -lfreetype"
export PNG_CFLAGS="-I$MAMP/include"
export PNG_LIBS="-L$MAMP/lib -lpng16"
export XSL_CFLAGS="-I$MAMP/include"
export XSL_LIBS="-L$MAMP/lib -lxslt -lxml2"
export EXSLT_LIBS="-L$MAMP/lib -lexslt"
export LIBSODIUM_CFLAGS="-I$MAMP/include"
export LIBSODIUM_LIBS="-L$MAMP/lib -lsodium"
export ARGON2_CFLAGS="-I$MAMP/include"
export ARGON2_LIBS="-L$MAMP/lib -largon2"
export EDIT_CFLAGS="-I$MAMP/include"
export EDIT_LIBS="-L$MAMP/lib -ledit"

# Version-specific flags
MAJOR_MINOR="${VERSION%.*}"
XMLRPC_FLAG=""
# xmlrpc was removed from PHP core in 8.3 (PECL extension only)

# PHP 8.4+ removed --with-zlib-dir and --with-kerberos
ZLIB_DIR_FLAG="--with-zlib-dir=$MAMP"
KERBEROS_FLAG="--with-kerberos"
KERBEROS_VAR_FLAGS="KERBEROS_CFLAGS=\"-I/usr/include\" KERBEROS_LIBS=\"-lkrb5\""
if [[ "$MAJOR_MINOR" == "8.4" ]] || [[ "$MAJOR_MINOR" == "8.5" ]] || [[ "$MAJOR_MINOR" == "8.6" ]]; then
  ZLIB_DIR_FLAG=""
  KERBEROS_FLAG=""
  KERBEROS_VAR_FLAGS=""
fi

# Hide old OpenSSL dylib symlinks — linker must find only the .a (OpenSSL 3) files.
# PHP_EVAL_LIBLINE emits -lssl -lcrypto; without hiding the symlinks the linker
# would pick libssl.dylib -> libssl.1.0.0.dylib (old OpenSSL) instead of libssl.a.
LIBSSL_SYM="$MAMP/lib/libssl.dylib"
LIBCRYPTO_SYM="$MAMP/lib/libcrypto.dylib"
LIBSSL_MOVED=0; LIBCRYPTO_MOVED=0

restore_ossl_symlinks() {
  [ $LIBSSL_MOVED -eq 1 ]    && mv "$MAMP/lib/libssl.dylib.hidden"    "$LIBSSL_SYM"    2>/dev/null || true
  [ $LIBCRYPTO_MOVED -eq 1 ] && mv "$MAMP/lib/libcrypto.dylib.hidden" "$LIBCRYPTO_SYM" 2>/dev/null || true
}
trap restore_ossl_symlinks EXIT

if [ -L "$LIBSSL_SYM" ]; then
  mv "$LIBSSL_SYM" "$MAMP/lib/libssl.dylib.hidden"; LIBSSL_MOVED=1
  echo "==> Hid libssl.dylib symlink for static linking"
fi
if [ -L "$LIBCRYPTO_SYM" ]; then
  mv "$LIBCRYPTO_SYM" "$MAMP/lib/libcrypto.dylib.hidden"; LIBCRYPTO_MOVED=1
  echo "==> Hid libcrypto.dylib symlink for static linking"
fi

cd "$SRC"

./configure \
  --with-apxs2=$MAMP/bin/apxs \
  --with-zlib $ZLIB_DIR_FLAG \
  --prefix="$PREFIX" \
  --exec-prefix="$PREFIX" \
  --sysconfdir="$PREFIX/conf" \
  --with-config-file-path="$PREFIX/conf" \
  --enable-ftp \
  --with-bz2=$MAMP \
  --with-mysqli=mysqlnd \
  --enable-mbstring=all \
  --with-curl=$MAMP \
  --enable-sockets \
  --enable-bcmath \
  --enable-soap \
  --enable-calendar \
  --enable-exif \
  --with-xsl=$MAMP \
  --with-pdo-mysql=mysqlnd \
  --with-openssl=$MAMP \
  ac_cv_func_RAND_egd=no \
  --enable-opcache \
  --with-tidy=shared,$MAMP \
  --with-readline=$MAMP \
  --with-mhash \
  --with-sodium=$MAMP \
  --with-password-argon2=$MAMP \
  --with-zip \
  $XMLRPC_FLAG \
  $KERBEROS_FLAG \
  --with-pdo-sqlite \
  --with-sqlite3 \
  --disable-phpdbg \
  --enable-cgi \
  --with-webp \
  --with-jpeg \
  --with-freetype \
  --enable-pcntl \
  --enable-intl \
  --with-iconv=$MAMP \
  --with-gettext=$MAMP \
  --enable-gd \
  --with-external-pcre=$MAMP \
  --with-ldap=$MAMP \
  --with-ldap-sasl=$MAMP \
  CFLAGS="-arch $ARCH" \
  LDFLAGS="-arch $ARCH -L$MAMP/lib" \
  KERBEROS_CFLAGS="-I/usr/include" \
  KERBEROS_LIBS="-lkrb5" \
  SQLITE_CFLAGS=" " \
  SQLITE_LIBS="-lsqlite3" \
  JPEG_CFLAGS=" " \
  JPEG_LIBS="-ljpeg" \
  SASL_CFLAGS="-I/usr/include/sasl" \
  SASL_LIBS="-lsasl2"

echo "Configure done for PHP $VERSION"
