#!/bin/bash
set -e

MAMP="/Applications/MAMP/Library"
BUILD="/tmp/php-build-${USER:-mamp}"
START_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSIONS=("8.2.32" "8.3.32" "8.4.23" "8.5.8")

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

for version in "${VERSIONS[@]}"; do
  echo "=================================================="
  echo "==> Configuring PHP $version"
  echo "=================================================="
  cd "$START_DIR"
  bash build-php-mamp.sh "$version"

  # Apply ICU make patch for PHP 8.3
  if [ "$version" = "8.3.32" ]; then
    echo "==> Applying ICU Makefile patch for PHP 8.3.32"
    python3 -c "import re; f='${BUILD}/php-8.3.32/Makefile'; c=open(f).read(); open(f,'w').write(re.sub(r'^(EXTRA_LIBS = .+)$', r'\1 -licuio', c, flags=re.MULTILINE))"
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

  # Copy and sign Apache module libphp.so into the PHP version's directory
  # (MAMP GUI scans for and dynamically copies this file to switch versions)
  LIBPHP_SRC=""
  if [ -f "libs/libphp.so" ]; then
    LIBPHP_SRC="libs/libphp.so"
  elif [ -f "modules/libphp.so" ]; then
    LIBPHP_SRC="modules/libphp.so"
  fi

  if [ -n "$LIBPHP_SRC" ]; then
    echo "==> Copying and signing Apache module libphp.so"
    mkdir -p "/Applications/MAMP/bin/php/php${version}/modules"
    cp "$LIBPHP_SRC" "/Applications/MAMP/bin/php/php${version}/modules/libphp.so"
    codesign --force --sign - "/Applications/MAMP/bin/php/php${version}/modules/libphp.so"
    
    # Also copy to global modules as fallback
    cp "$LIBPHP_SRC" "$MAMP/modules/"
    codesign --force --sign - "$MAMP/modules/libphp.so"
  fi
done

echo "All PHP versions built and installed successfully!"
