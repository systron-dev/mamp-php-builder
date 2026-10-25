#!/bin/bash
set -e
# bison/re2c from MacPorts are needed when PHP's parser/lexer are rebuilt.
# They are added only to `make`, never to configure: a MacPorts pkg-config on
# PATH could leak /opt/local libraries into the build.

MAMP="/Applications/MAMP/Library"
BUILD="/tmp/php-build-${USER:-mamp}"
START_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-arch.sh
source "$START_DIR/lib-arch.sh"
VERSIONS=("8.2.35" "8.3.36" "8.4.27" "8.5.12" "8.6.0RC4")
# Optional: pass versions as arguments to build a subset, e.g. `./compile-all-php.sh 8.6.0RC4`
if [ $# -gt 0 ]; then
  VERSIONS=("$@")
fi

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

# Hide old OpenSSL dylibs for static linking. restore_openssl_dylibs keys off
# the .hidden backup, so a signal between `mv` and any flag cannot lose it.
trap 'restore_openssl_dylibs "$MAMP/lib"' EXIT
trap 'restore_openssl_dylibs "$MAMP/lib"; exit 130' INT TERM

VERSION_ERRORS=0

for version in "${VERSIONS[@]}"; do
  # MAMP Pro discovers versions via regex ^/Applications/MAMP/bin/php/php[578]\.[0-9]\.[0-9]{1,2}/bin$
  # so RC/beta builds install into the numeric-only dir (8.6.0RC4 -> php8.6.0).
  install_version=$(printf '%s' "$version" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  echo "=================================================="
  echo "==> Configuring PHP $version (install dir: php${install_version})"
  echo "=================================================="
  cd "$START_DIR"
  bash build-php-mamp.sh "$version"

  # Apply ICU make patch for PHP 8.3 (all 8.3.x point releases)
  if [[ "$version" == 8.3.* ]]; then
    echo "==> Applying ICU Makefile patch for PHP $version"
    python3 -c "import re; f='${BUILD}/php-${version}/Makefile'; c=open(f).read(); open(f,'w').write(re.sub(r'^(EXTRA_LIBS = .+)$', r'\1 -licuio', c, flags=re.MULTILINE))"
  fi

  echo "==> Hiding OpenSSL dylibs for static compilation"
  hide_openssl_dylibs "$MAMP/lib"

  # Compile PHP
  echo "==> Compiling PHP $version"
  cd "${BUILD}/php-${version}"
  PATH="/opt/local/bin:$PATH" make -j$(sysctl -n hw.ncpu)

  echo "==> Restoring OpenSSL dylibs"
  restore_openssl_dylibs "$MAMP/lib"

  echo "==> Installing PHP $version"
  make install

  # Modules built by PHP's own configure (tidy, opcache-less 8.5+) are not
  # touched by build-mamp-ext.sh; normalize and sign them here so no module
  # ships with an @rpath or foreign linkage.
  ext_dir=$(ls -d "/Applications/MAMP/bin/php/php${install_version}"/lib/php/extensions/* 2>/dev/null | head -1)
  # Only tidy is built by PHP's own configure here; extension modules are owned
  # by build-mamp-ext.sh and must not be rewritten by this pass.
  if [ -n "$ext_dir" ] && [ -f "$ext_dir/tidy.so" ]; then
    if ! MAMPLIB="$MAMP/lib" normalize_module_links "$ext_dir/tidy.so"; then
      echo "ERROR: could not normalize/sign $ext_dir/tidy.so" >&2
      VERSION_ERRORS=$((VERSION_ERRORS + 1))
    fi
  fi

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
    mkdir -p "/Applications/MAMP/bin/php/php${install_version}/modules"
    cp "$LIBPHP_SRC" "/Applications/MAMP/bin/php/php${install_version}/modules/libphp.so"
    codesign --force --sign - "/Applications/MAMP/bin/php/php${install_version}/modules/libphp.so"
    
    # Also copy to global modules as fallback
    cp "$LIBPHP_SRC" "$MAMP/modules/"
    codesign --force --sign - "$MAMP/modules/libphp.so"
  fi
done

if [ "$VERSION_ERRORS" -ne 0 ]; then
  echo "PHP builds finished with $VERSION_ERRORS version(s) needing attention." >&2
  exit 1
fi
echo "All PHP versions built and installed successfully!"
