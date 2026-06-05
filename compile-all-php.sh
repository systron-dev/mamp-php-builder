#!/bin/bash
set -e

MAMP="/Applications/MAMP/Library"
BUILD="/tmp/php-build-${USER:-mamp}"
VERSIONS=("8.2.31" "8.3.31" "8.4.21" "8.5.6")

for version in "${VERSIONS[@]}"; do
  echo "=================================================="
  echo "==> Configuring PHP $version"
  echo "=================================================="
  cd "/Users/slackero/Downloads/mamp-php-builder"
  bash build-php-mamp.sh "$version"

  # Apply ICU make patch for PHP 8.3
  if [ "$version" = "8.3.31" ]; then
    echo "==> Applying ICU Makefile patch for PHP 8.3.31"
    python3 -c "import re; f='${BUILD}/php-8.3.31/Makefile'; c=open(f).read(); open(f,'w').write(re.sub(r'^(EXTRA_LIBS = .+)$', r'\1 -licuio', c, flags=re.MULTILINE))"
  fi

  echo "==> Hiding OpenSSL dylibs for static compilation"
  LIBSSL_SYM="$MAMP/lib/libssl.dylib"
  LIBCRYPTO_SYM="$MAMP/lib/libcrypto.dylib"
  LIBSSL_MOVED=0; LIBCRYPTO_MOVED=0

  if [ -L "$LIBSSL_SYM" ]; then
    mv "$LIBSSL_SYM" "$MAMP/lib/libssl.dylib.hidden"
    LIBSSL_MOVED=1
  fi
  if [ -L "$LIBCRYPTO_SYM" ]; then
    mv "$LIBCRYPTO_SYM" "$MAMP/lib/libcrypto.dylib.hidden"
    LIBCRYPTO_MOVED=1
  fi

  # Compile PHP
  echo "==> Compiling PHP $version"
  cd "${BUILD}/php-${version}"
  make -j$(sysctl -n hw.ncpu)

  echo "==> Restoring OpenSSL dylibs"
  if [ $LIBSSL_MOVED -eq 1 ]; then
    mv "$MAMP/lib/libssl.dylib.hidden" "$LIBSSL_SYM"
  fi
  if [ $LIBCRYPTO_MOVED -eq 1 ]; then
    mv "$MAMP/lib/libcrypto.dylib.hidden" "$LIBCRYPTO_SYM"
  fi

  echo "==> Installing PHP $version"
  make install

  # Copy and sign Apache module libphp.so
  if [ -f "modules/libphp.so" ]; then
    echo "==> Copying and signing modules/libphp.so"
    cp "modules/libphp.so" "$MAMP/modules/"
    codesign --force --sign - "$MAMP/modules/libphp.so"
  fi
done

echo "All PHP versions built and installed successfully!"
