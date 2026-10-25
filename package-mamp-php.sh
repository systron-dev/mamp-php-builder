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
  # Deployment-target floor: refuse to publish binaries newer than macOS 12.0.
  max_minos=0
  for bin in "$target_dir/bin/php" "$target_dir/bin/php-cgi" "$target_dir/modules/libphp.so" \
             "$target_dir"/lib/php/extensions/*/*.so; do
    [ -e "$bin" ] || continue
    m=$(otool -l "$bin" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
    [ -n "$m" ] || m=$(otool -l "$bin" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')
    [ -n "$m" ] || continue
    max_minos=$(awk -v a="$max_minos" -v b="$m" 'BEGIN{split(a,x,".");split(b,y,".");print (y[1]>x[1]||(y[1]==x[1]&&y[2]>x[2])||(y[1]==x[1]&&y[2]==x[2]&&y[3]>x[3]))?b:a}')
  done
  if [ "${ALLOW_NEWER_MINOS:-0}" != "1" ] && \
     awk -v m="$max_minos" 'BEGIN{split(m,a,".");exit !(a[1]>12 || (a[1]==12 && (a[2]>0 || a[3]>0)))}'; then
    echo "ERROR: $target_dir needs macOS $max_minos (floor is 12.0) — rebuild with MACOSX_DEPLOYMENT_TARGET=12.0." >&2
    PKG_ERRORS=$((PKG_ERRORS + 1))
    rm -f "$archive_path" "${archive_path}.sha256"
    continue
  fi

  if [ ! -x "$target_dir/bin/php" ]; then
    echo "ERROR: $target_dir/bin/php is missing or not executable — partial install, skipping." >&2
    PKG_ERRORS=$((PKG_ERRORS + 1))
    rm -f "$archive_path" "${archive_path}.sha256"
    continue
  fi

  # Never ship a binary built for the other architecture under an -$ARCH name.
  # Architecture checks feed PKG_ERRORS instead of exiting: one bad version
  # must not stop the remaining archives from being produced.
  arch_ok() {
    local f a
    for f in "$@"; do
      if [ -L "$f" ] && [ ! -e "$f" ]; then
        echo "ERROR: $f is a dangling symlink" >&2
        return 1
      fi
      [ -e "$f" ] || continue
      a=$(lipo -archs "$f" 2>/dev/null || true)
      case " $a " in
        *" $ARCH "*) ;;
        *) echo "ERROR: $f is '$a', expected $ARCH" >&2; return 1 ;;
      esac
    done
  }
  if ! arch_ok "$target_dir/bin/php" "$target_dir/bin/php-cgi" \
              "$target_dir/modules/libphp.so" "$target_dir"/lib/php/extensions/*/*.so; then
    PKG_ERRORS=$((PKG_ERRORS + 1))
    rm -f "$archive_path" "${archive_path}.sha256"
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

if [ "$PKG_ERRORS" -ne 0 ]; then
  echo "==> Packaging finished with $PKG_ERRORS error(s)." >&2
  exit 1
fi
echo "==> Packaging complete!"
