#!/bin/bash
# Package pre-built MAMP PHP installations into dist/
# Usage: ./package-mamp-php.sh [version ...]
# Examples:
#   ./package-mamp-php.sh
#   ./package-mamp-php.sh 8.6.0RC4

set -euo pipefail

START_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${START_DIR}/dist"
# Native-only: arm64 on Apple Silicon, x86_64 on Intel (ignores Rosetta process arch).
source "$START_DIR/lib-arch.sh"
PHP_BASE="/Applications/MAMP/bin/php"

VERSIONS=("8.2.35" "8.3.36" "8.4.27" "8.5.12" "8.6.0RC4")
if [ $# -gt 0 ]; then
  VERSIONS=("$@")
fi

mkdir -p "$DIST_DIR"
PKG_ERRORS=0

for version in "${VERSIONS[@]}"; do
  # MAMP Pro requires numeric install dirs (8.6.0RC4 -> php8.6.0)
  install_version=$(printf '%s' "$version" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  target_dir="${PHP_BASE}/php${install_version}"
  archive_name="php${version}-${ARCH}.tar.gz"
  archive_path="${DIST_DIR}/${archive_name}"

  if [ ! -d "$target_dir" ]; then
    echo "==> [SKIP] Directory not found: $target_dir"
    continue
  fi
  if [ ! -x "$target_dir/bin/php" ]; then
    echo "ERROR: $target_dir/bin/php is missing or not executable — partial install, skipping." >&2
    PKG_ERRORS=$((PKG_ERRORS + 1))
    continue
  fi

  # Never ship a binary built for the other architecture under an -$ARCH name.
  require_native "$target_dir/bin/php"
  for extra in "$target_dir/bin/php-cgi" "$target_dir/modules/libphp.so"; do
    [ -e "$extra" ] && require_native "$extra"
  done
  # Extensions are dlopen()ed by that binary; a stale copy from another arch
  # would make the archive unusable even though bin/php itself is native.
  for ext_dir in "$target_dir"/lib/php/extensions/*/; do
    [ -d "$ext_dir" ] || continue
    require_native "$ext_dir"*.so
  done

  echo "==> Packaging PHP ${version} (${ARCH}) from ${target_dir}..."
  (
    cd "$PHP_BASE"
    tar -czf "$archive_path" "php${install_version}"
  )

  echo "==> Created ${archive_path} ($(ls -lh "$archive_path" | awk '{print $5}'))"
  shasum -a 256 "$archive_path" > "${archive_path}.sha256"
  echo "==> Created ${archive_path}.sha256"
done

if [ "$PKG_ERRORS" -ne 0 ]; then
  echo "==> Packaging finished with $PKG_ERRORS error(s)." >&2
  exit 1
fi
echo "==> Packaging complete!"
