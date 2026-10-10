#!/bin/bash
# Package pre-built MAMP PHP installations into dist/
# Usage: ./package-mamp-php.sh [version ...]
# Examples:
#   ./package-mamp-php.sh
#   ./package-mamp-php.sh 8.6.0RC3

set -euo pipefail

START_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${START_DIR}/dist"
ARCH="$(uname -m)"  # arm64 on Apple Silicon, x86_64 on Intel
PHP_BASE="/Applications/MAMP/bin/php"

VERSIONS=("8.2.34" "8.3.35" "8.4.26" "8.5.11" "8.6.0RC3")
if [ $# -gt 0 ]; then
  VERSIONS=("$@")
fi

mkdir -p "$DIST_DIR"

for version in "${VERSIONS[@]}"; do
  # MAMP Pro requires numeric install dirs (8.6.0RC3 -> php8.6.0)
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
done

echo "==> Packaging complete!"
