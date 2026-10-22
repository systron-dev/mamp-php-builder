#!/bin/bash
# Package pre-built MAMP PHP installations into dist/
# Usage: ./package-mamp-php.sh [version ...]
# Examples:
#   ./package-mamp-php.sh
#   ./package-mamp-php.sh 8.6.0RC4

set -euo pipefail

START_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${START_DIR}/dist"
ARCH="$(uname -m)"  # arm64 on Apple Silicon, x86_64 on Intel
PHP_BASE="/Applications/MAMP/bin/php"

VERSIONS=("8.2.35" "8.3.36" "8.4.27" "8.5.12" "8.6.0RC4")
if [ $# -gt 0 ]; then
  VERSIONS=("$@")
fi

mkdir -p "$DIST_DIR"

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

  echo "==> Packaging PHP ${version} (${ARCH}) from ${target_dir}..."
  (
    cd "$PHP_BASE"
    tar -czf "$archive_path" "php${install_version}"
  )

  echo "==> Created ${archive_path} ($(ls -lh "$archive_path" | awk '{print $5}'))"
  shasum -a 256 "$archive_path" > "${archive_path}.sha256"
  echo "==> Created ${archive_path}.sha256"
done

echo "==> Packaging complete!"
