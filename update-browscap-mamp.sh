#!/bin/bash
# Update MAMP's shared /Applications/MAMP/bin/php/browscap.ini from browscap.org.
#
# Supports all 3 official PHP browscap.ini editions from browscap.org:
#   - lite     (Lite_PHP_BrowsCapINI) : smaller file with major browsers & search engines (MAMP default)
#   - special  (PHP_BrowsCapINI)      : special version of browscap.ini for PHP users
#   - full     (Full_PHP_BrowsCapINI) : larger version of php_browscap.ini with all properties
#
# Checks https://browscap.org/version-number first to respect browscap.org rate limits,
# downloads the requested PHP browscap stream to a temporary file, validates its INI
# headers and PHP get_browser() parsing, and atomically replaces the target file.
#
# Usage:
#   bash update-browscap-mamp.sh [lite|special|full] [--force]
#   bash update-browscap-mamp.sh [--type=lite|special|full] [--force]
# Environment variables:
#   BROWSCAP_FILE  Target path (default: /Applications/MAMP/bin/php/browscap.ini)
#   BROWSCAP_TYPE  Edition: lite (default), special, or full
#   FORCE          Set to 1 to download even when the installed version & type match upstream

set -euo pipefail

BROWSCAP_FILE="${BROWSCAP_FILE:-/Applications/MAMP/bin/php/browscap.ini}"
BROWSCAP_TYPE="${BROWSCAP_TYPE:-lite}"
FORCE="${FORCE:-0}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X) mamp-php-builder/1.0"

usage() {
  cat <<EOF
Usage: $0 [lite|special|full] [--type=lite|special|full] [--force]

Editions (Format=php):
  lite      lite_php_browscap.ini (Lite_PHP_BrowsCapINI, Type=LITE) — MAMP default
  special   php_browscap.ini      (PHP_BrowsCapINI, special version for PHP users)
  full      full_php_browscap.ini (Full_PHP_BrowsCapINI, Type=FULL)

Options:
  -t, --type <edition>   Select edition: lite, special, or full
  -f, --force            Re-download even if installed version and edition match upstream
  -h, --help             Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force)
      FORCE=1
      ;;
    -t|--type)
      if [ $# -lt 2 ]; then
        echo "ERROR: $1 requires an argument (lite, special, or full)." >&2
        exit 1
      fi
      BROWSCAP_TYPE="$2"
      shift
      ;;
    --type=*)
      BROWSCAP_TYPE="${1#*=}"
      ;;
    --lite|lite|LITE|Lite_PHP_BrowsCapINI)
      BROWSCAP_TYPE="lite"
      ;;
    --special|special|SPECIAL|standard|default|php|STANDARD|PHP_BrowsCapINI)
      BROWSCAP_TYPE="special"
      ;;
    --full|full|FULL|Full_PHP_BrowsCapINI)
      BROWSCAP_TYPE="full"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument '$1'. Use --help for usage." >&2
      exit 1
      ;;
  esac
  shift
done

case "$BROWSCAP_TYPE" in
  lite|LITE|Lite_PHP_BrowsCapINI)
    EDITION="lite"
    QUERY="Lite_PHP_BrowsCapINI"
    EXPECTED_TYPE="LITE"
    ;;
  special|SPECIAL|standard|default|php|STANDARD|PHP_BrowsCapINI)
    EDITION="special"
    QUERY="PHP_BrowsCapINI"
    EXPECTED_TYPE=""
    ;;
  full|FULL|Full_PHP_BrowsCapINI)
    EDITION="full"
    QUERY="Full_PHP_BrowsCapINI"
    EXPECTED_TYPE="FULL"
    ;;
  *)
    echo "ERROR: Unsupported BROWSCAP_TYPE '$BROWSCAP_TYPE' (expected: lite, special, or full)." >&2
    exit 1
    ;;
esac

format_type_label() {
  local raw_type="${1:-}"
  case "$raw_type" in
    LITE) echo "lite (Lite_PHP_BrowsCapINI)" ;;
    FULL) echo "full (Full_PHP_BrowsCapINI)" ;;
    "")   echo "special (PHP_BrowsCapINI)" ;;
    *)    echo "$raw_type" ;;
  esac
}

read_ini_field() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -F= -v k="$key" '
    /^\[GJK_Browscap_Version\]/ { in_sec=1; next }
    in_sec && /^\[/ { in_sec=0 }
    in_sec && $1 == k {
      sub(/^[^=]*=/, "")
      sub(/\r$/, "")
      print
      exit
    }
  ' "$file"
}

current_version=$(read_ini_field "$BROWSCAP_FILE" "Version" | tr -d '[:space:]')
current_released=$(read_ini_field "$BROWSCAP_FILE" "Released")
current_type=$(read_ini_field "$BROWSCAP_FILE" "Type" | tr -d '[:space:]')

if [ -f "$BROWSCAP_FILE" ]; then
  echo "==> Current $BROWSCAP_FILE: Version=${current_version:-unknown}, Edition=$(format_type_label "$current_type"), Released=${current_released:-unknown}"
else
  echo "==> $BROWSCAP_FILE does not exist yet; will download fresh copy."
fi

remote_version=$(curl -fsSL --retry 2 --max-time 15 -A "$UA" "https://browscap.org/version-number" 2>/dev/null | tr -d '[:space:]\r' || true)

if [ "$FORCE" != "1" ] && [ -n "$remote_version" ] && [ "$current_version" = "$remote_version" ] && [ "$current_type" = "$EXPECTED_TYPE" ]; then
  echo "==> browscap.ini is already up to date (Version=${current_version}, Edition=$(format_type_label "$current_type"))."
  exit 0
fi

if [ -n "$remote_version" ]; then
  echo "==> Upstream browscap version: $remote_version (fetching '$EDITION' stream: $QUERY)..."
else
  echo "==> Fetching browscap '$EDITION' stream ($QUERY) from browscap.org..."
fi

target_dir=$(dirname "$BROWSCAP_FILE")
if [ ! -d "$target_dir" ]; then
  echo "ERROR: Target directory $target_dir does not exist." >&2
  exit 1
fi

tmp_file="${BROWSCAP_FILE}.tmp.$$"
trap 'rm -f "$tmp_file"' EXIT

curl -fsSL --retry 2 --max-time 180 -A "$UA" "https://browscap.org/stream?q=${QUERY}" -o "$tmp_file"

new_version=$(read_ini_field "$tmp_file" "Version" | tr -d '[:space:]')
new_released=$(read_ini_field "$tmp_file" "Released")
new_format=$(read_ini_field "$tmp_file" "Format" | tr -d '[:space:]')
new_type=$(read_ini_field "$tmp_file" "Type" | tr -d '[:space:]')

if [ -z "$new_version" ] || [ "$new_format" != "php" ] || ! grep -q '^\[DefaultProperties\]' "$tmp_file"; then
  echo "ERROR: Downloaded file is not a valid PHP browscap.ini (Version='${new_version}', Format='${new_format}')." >&2
  head -n 20 "$tmp_file" >&2 || true
  exit 1
fi

# Smoke-test parsing with an installed MAMP PHP binary if available.
php_bin=$(ls /Applications/MAMP/bin/php/php8.*/bin/php /Applications/MAMP/bin/php/php7.*/bin/php 2>/dev/null | tail -n 1 || true)
if [ -n "$php_bin" ] && [ -x "$php_bin" ]; then
  if ! "$php_bin" -n -d memory_limit=512M -d browscap="$tmp_file" -r '$b = get_browser("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36", true); exit(is_array($b) && isset($b["browser"]) ? 0 : 1);'; then
    echo "ERROR: PHP get_browser() smoke test failed with $php_bin" >&2
    exit 1
  fi
fi

chmod 0664 "$tmp_file" 2>/dev/null || chmod 0644 "$tmp_file"
mv "$tmp_file" "$BROWSCAP_FILE"

file_size=$(ls -lh "$BROWSCAP_FILE" | awk '{print $5}')
echo "==> Updated $BROWSCAP_FILE ($file_size): Version=${new_version}, Edition=$(format_type_label "$new_type"), Released=${new_released}"
