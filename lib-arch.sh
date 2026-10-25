#!/bin/bash
# Shared native-architecture detection for the build scripts.
#
# Builds are always native: arm64 on Apple Silicon, x86_64 on Intel. The
# *process* architecture is deliberately ignored, so running a build from a
# Rosetta 2 shell still produces native binaries instead of silently
# installing an Intel PHP into the same /Applications/MAMP/bin/php/phpX.Y
# directory as the native build.
#
# Source this file; it sets $ARCH.

if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
  ARCH=arm64
else
  ARCH=x86_64
fi
export ARCH

if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
  echo "==> NOTE: running under Rosetta 2 — building native $ARCH anyway" >&2
fi

# require_native <file> [<file> ...]
# Aborts when a prebuilt library or binary does not contain $ARCH. Prevents
# late, confusing linker errors from a MAMP Library tree populated on the
# other architecture. Universal (fat) files pass.
require_native() {
  local f archs
  for f in "$@"; do
    [ -e "$f" ] || continue
    archs=$(lipo -archs "$f" 2>/dev/null || true)
    if [ -z "$archs" ]; then
      echo "ERROR: cannot determine architecture of $f (truncated or not Mach-O)." >&2
      exit 1
    fi
    case " $archs " in
      *" $ARCH "*) ;;
      *)
        echo "ERROR: $f is built for '$archs', expected '$ARCH'." >&2
        echo "       Rebuild it on this machine (build-zlib-mamp.sh for libz," >&2
        echo "       build-deps-mamp.sh all for OpenSSL/curl and the rest) and retry." >&2
        exit 1
        ;;
    esac
  done
}

# workcopy <source-dir>
#
# Version-specific source patches must not leak into the cached $SRC tree, so
# they are applied to a throwaway copy. Build output from earlier runs is
# skipped (phpize --clean deletes it anyway) to avoid duplicating hundreds of
# megabytes per version. Echoes the copy's path.
workcopy() {
  local src=$1 work
  work="$BUILD/ext-work-$(basename "$src")-$$"
  # Only this process's tree: another build may be using a sibling PID copy.
  rm -rf "$work"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude '.libs' --exclude 'modules' --exclude '*.dSYM' \
      --exclude 'autom4te.cache' --exclude '*.o' --exclude '*.lo' --exclude '*.la' \
      "$src"/ "$work"/ || { echo "ERROR: workcopy failed for $src" >&2; return 1; }
  else
    cp -R "$src" "$work" || { echo "ERROR: workcopy failed for $src" >&2; return 1; }
    rm -rf "$work/.libs" "$work/modules" "$work/autom4te.cache"
    find "$work" -maxdepth 2 \( -name '*.dSYM' -o -name '*.o' -o -name '*.lo' -o -name '*.la' \) \
      -exec rm -rf {} + 2>/dev/null || true
  fi
  echo "$work"
}

# normalize_module_links <module.so> ...
#
# Makes a module self-contained: @rpath dependencies are rewritten to absolute
# MAMP Library paths, LC_RPATH entries outside MAMP are deleted, and the module
# is re-signed. Fails when a dependency cannot be resolved into MAMP Library:
# keeping the rpath would make the module work only through a temporary build
# prefix, which breaks the "no /tmp or /opt/local linkage" rule.
# Callers define MAMPLIB as either the Library root or its lib directory.
normalize_module_links() {
  local so dep base rp unresolved rc=0 libdir sign=${NORMALIZE_SIGN:-1} resolved
  case "$MAMPLIB" in
    */lib) libdir=$MAMPLIB ;;
    *)     libdir=$MAMPLIB/lib ;;
  esac
  local mamp_root
  mamp_root=$(dirname "$libdir")
  for so in "$@"; do
    [ -f "$so" ] || continue
    unresolved=0
    # Rewrite @rpath and absolute build-prefix/Homebrew deps to MAMP Library.
    # A module must never keep /tmp or /opt/local linkage, even if the linker
    # resolved it eagerly and the module loads today.
    for dep in $(otool -L "$so" | awk 'NR > 1 {print $1}'); do
      case "$dep" in
        @rpath/*) ;;
        @loader_path/*|@executable_path/*)
          echo "ERROR: $(basename "$so"): $dep is relative and cannot be made self-contained" >&2
          unresolved=1
          rc=1
          continue
          ;;
        /tmp/*|/private/tmp/*) ;;
        /opt/local/*|/opt/homebrew/*|/usr/local/*)
          echo "ERROR: $(basename "$so"): foreign dependency $dep (Homebrew/MacPorts)" >&2
          unresolved=1
          rc=1
          continue
          ;;
        *) continue ;;
      esac
      base=$(basename "$dep")
      resolved="$libdir/$base"
      # MAMP also stores dylibs outside Library/lib (pg/lib, imap-2007f/lib, ...).
      if [ ! -e "$resolved" ]; then
        resolved=$(find "$mamp_root" -maxdepth 4 -name "$base" -print -quit 2>/dev/null)
      fi
      if [ -n "$resolved" ] && [ -e "$resolved" ]; then
        if ! install_name_tool -change "$dep" "$resolved" "$so" 2>/dev/null; then
          echo "ERROR: $(basename "$so"): cannot rewrite $dep (file not writable?)" >&2
          unresolved=1
          rc=1
        fi
      else
        echo "ERROR: $(basename "$so"): unresolved $dep (not under $mamp_root)" >&2
        unresolved=1
        rc=1
      fi
    done
    if [ "$unresolved" -eq 0 ]; then
      for rp in $(otool -l "$so" | awk '/LC_RPATH/{getline;getline;print $2}'); do
        case "$rp" in
          "$mamp_root"|"$mamp_root"/*) ;;
          *) install_name_tool -delete_rpath "$rp" "$so" 2>/dev/null || true ;;
        esac
      done
    fi
    # Sign whenever a load command was rewritten: install_name_tool always
    # invalidates the existing ad-hoc signature.
    if [ "$sign" -eq 1 ]; then
      if ! codesign --force --sign - "$so" 2>/dev/null; then
        echo "ERROR: $(basename "$so"): code signing failed" >&2
        rc=1
      fi
    fi
  done
  return $rc
}

# require_native_mamp_libs <library-root>
#
# Checks every MAMP artifact a native build depends on, including the dylibs
# the shipped bin/php actually loads (the .a files are link-time only).
require_native_mamp_libs() {
  local root=$1
  require_native "$root/lib/libssl.a" "$root/lib/libcrypto.a" \
    "$root/lib/libz.a" "$root/lib/libcurl.a" \
    "$root/lib/libz.1.dylib" "$root/lib/libcurl.4.dylib"
}

# install_modules <extdir>
#
# Normalizes and signs the modules just built in ./modules, copies them into
# <extdir>, then re-signs the installed copies (macOS validates what is
# installed). Returns 3 when a module cannot be made self-contained, 4 when
# signing the installed copy fails, and 1 when the copy fails, so the caller can
# tell a broken build from a permission problem. Must be called from the extension's build directory.
install_modules() {
  local extdir=$1 f
  # Sign before installing: if signing fails, nothing broken reaches the PHP
  # extension dir. The copies are re-signed below as macOS validates those.
  # Sign the installed copies below; do not spend a second codesign on the
  # build-tree copies (the dist fallback signs its own).
  NORMALIZE_SIGN=0 normalize_module_links modules/*.so || return 3
  cp modules/*.so "$extdir/" 2>/dev/null || return 1
  for f in modules/*.so; do
    [ -f "$f" ] || continue
    if ! codesign --force --sign - "$extdir/$(basename "$f")" 2>/dev/null; then
      echo "ERROR: $(basename "$f"): code signing the installed copy failed" >&2
      return 4
    fi
  done
  return 0
}

# patch_hashkit_makefile <srcdir>
#
# libmemcached-awesome 1.1.4 splits libhashkit.a out but its .pc omits
# -lhashkit. PHP links modules with -undefined dynamic_lookup, so the missing
# hashkit_* symbols bind to 0x0 and new Memcached() crashes. Adds the flag to
# the memcached Makefile, and fails loudly if the anchor is gone.
patch_hashkit_makefile() {
  local srcdir=$1
  case "$(basename "$srcdir")" in
    *memcached-*) ;;
    *) return 0 ;;
  esac
  [ -f Makefile ] || return 0
  grep -q -- '-lhashkit' Makefile || \
    sed -i.bak -E 's|^(MEMCACHED_SHARED_LIBADD = .*)$|\1 -lhashkit|' Makefile
  if ! grep -q -- '-lhashkit' Makefile; then
    echo "ERROR: $(basename "$srcdir"): could not add -lhashkit (memcached would crash)" >&2
    return 1
  fi
}

# hide_openssl_dylibs <libdir> / restore_openssl_dylibs <libdir>
#
# MAMP ships OpenSSL 1.0 dylibs next to the static OpenSSL 3 archives; the
# linker must find only the .a files. Restoring keys off the backup file rather
# than a "moved" flag, so a signal between `mv` and the flag assignment cannot
# leave MAMP without libssl.dylib. The backup is always a symlink, hence -L.
hide_openssl_dylibs() {
  local libdir=$1 sym
  for sym in libssl.dylib libcrypto.dylib; do
    [ -e "$libdir/$sym" ] || [ -L "$libdir/$sym" ] || continue
    mv "$libdir/$sym" "$libdir/$sym.hidden"
  done
}

restore_openssl_dylibs() {
  local libdir=$1 sym
  for sym in libssl.dylib libcrypto.dylib; do
    if [ -e "$libdir/$sym.hidden" ] || [ -L "$libdir/$sym.hidden" ]; then
      mv "$libdir/$sym.hidden" "$libdir/$sym" 2>/dev/null \
        || echo "WARN: could not restore $libdir/$sym — backup kept at $sym.hidden" >&2
    fi
  done
}
