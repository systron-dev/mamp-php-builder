# AI Agent Guidelines & Context

This repository contains build scripts and documentation for compiling custom PHP builds for MAMP 6.9 on macOS (Apple Silicon and Intel).

## Key Environment & Architectural Constraints

- **MAMP 6.9.1 Self-Contained Requirement**: All runtime libraries must live strictly in `/Applications/MAMP/Library` (`$MAMPLIB`). Never introduce runtime dependencies on Homebrew (`/opt/homebrew` or `/usr/local`) or MacPorts (`/opt/local`). Verify with `otool -L` on `bin/php` and every `.so`.
- **MacPorts Build Basis**: MacPorts is used at build time for tools/headers only (`pkgconfig`, `autoconf`, `libtool`, `gettext`). `cmake` is auto-bootstrapped. Do not link MacPorts libraries — their dylibs carry `/opt/local` install names and `minos 27.0`.
- **OpenSSL 3 Static Linking**: MAMP's dynamic `libssl`/`libcrypto` are still the old 1.0.0. OpenSSL **3.6.5** static libraries (`libssl.a`, `libcrypto.a`) live in `/Applications/MAMP/Library` and are what PHP links. Whenever linking against OpenSSL, dynamic symlinks (`libssl.dylib`, `libcrypto.dylib`) in MAMP Library must be temporarily hidden so the linker finds only the `.a` files.
- **`OPENSSL_LIBS`**: Must use `-L$MAMP/lib -lssl -lcrypto` flags instead of direct `.a` paths because PHP configure's `PHP_EVAL_LIBLINE` drops raw `.a` paths.
- **Security Baseline**: Only package `8.2.35`, `8.3.36`, `8.4.27`, `8.5.12`, or `8.6.0RC4`. Each contains the upstream fixes for [CVE-2026-109618](https://www.cve.org/CVERecord?id=CVE-2026-109618) and [CVE-2026-109619](https://www.cve.org/CVERecord?id=CVE-2026-109619) (CVSS 9.2), confirmed in the php-src `NEWS` file for the tag. Never package 8.6.0RC3 or earlier point releases from `dist/`.
- **Deployment Target Floor**: Always ensure `MACOSX_DEPLOYMENT_TARGET=12.0` (Monterey floor) for portable binaries across macOS versions.
- **Library Modernization**: Phase A is done (`build-zlib-mamp.sh`, `build-deps-mamp.sh`): zlib 1.3.2, OpenSSL 3.6.5 static, nghttp2 1.70, curl 8.23, libpng 1.6.59, freetype 2.15, libzip 1.12, tidy 5.8, libsodium 1.0.22, webp 1.6, oniguruma 6.9.10. ICU 56.1, libxml2 2.9.4, libxslt 1.1.28 remain phase B (libxml2 ≥ 2.12 breaks PHP 5.6/7.4; libxslt 1.1.45 requires libxml2 ≥ 2.15.1).
- **Soname Bumps**: libsodium 23→26 and tidy 5.6→58 required rebuilding PHP. Compat symlinks `libsodium.23.dylib` and `libtidy.5.dylib` keep legacy `php7.4.33` working. After any phase A run, always rerun `./compile-all-php.sh`.
- **Codesigning**: `build-mamp-ext.sh` signs installed `.so` files after copying. Signing only the build-tree module causes `CODESIGNING: Invalid Page` kills on arm64 (seen with PHP 8.6).
- **Bundling**: `normalize_module_links()` rewrites every `@rpath` dependency to an absolute `/Applications/MAMP/Library/lib/...` path, deletes LC_RPATH entries outside MAMP (notably `/tmp/.../ext-deps`), and re-signs. No extension may retain `/opt/local` or `/tmp` linkage; verify with `otool -L` and `otool -l | grep LC_RPATH`.

## Directory Structure & Version Naming

- **Install Path Convention**: MAMP Pro GUI searches directories matching:
  `^/Applications/MAMP/bin/php/php[578]\.[0-9]\.[0-9]{1,2}/bin$`
- **Pre-releases**: Pre-releases (such as `8.6.0RC4`) must be installed under their numeric name (e.g. `php8.6.0`). The scripts (`build-php-mamp.sh`, `compile-all-php.sh`, `package-mamp-php.sh`) automatically handle this suffix stripping.
- **MAMP PRO GUI Compatibility Limit**: Versions `>= 8.5.0` are filtered out by MAMP PRO v6.x GUI dropdown due to internal hardcoded version checks, but work fully for CLI and custom Apache/CGI setups.

## PHP 8.5 & 8.6 Specifics

- **OPcache**: Compiled statically into PHP core for 8.5+ and 8.6. `opcache.so` does not exist. Do not load `zend_extension=...opcache.so` dynamically in `conf/php.ini`.
- **PHP 8.6 FreeType / GD**: Requires `-DHAVE_FT2BUILD_H` in `FREETYPE2_CFLAGS` and `#define HAVE_FT2BUILD_H 1` in `main/php_config.h`.
- **PHP 8.6 WebP**: Requires `libwebpdemux` and `libwebpmux` in `WEBP_LIBS`.
- **PHP 8.6 PECL Extensions**: Run via `bash build-mamp-ext.sh ext86`. Built successfully: `tidy` (core), `apcu`, `igbinary`, `imagick`, `mcrypt`, `memcached`, `oauth`, `redis`, `ssh2`, `uploadprogress`, `xdebug`, `yaml`, `pgsql`, `pdo_pgsql`, `sysvsem`, `sysvshm`, `sysvmsg`, `shmop`. This relies on `php86-compat.h` (force-included for 8.6 extension builds) restoring removed macros: `XtOffsetOf`, `zval_dtor`, `zval_is_true`, `INI_STR/INT/FLT/BOOL`, `WRONG_PARAM_COUNT`, `php_hash_bin2hex`. Do not build `imap`: removed from PHP core in 8.4; PECL imap needs UW `c-client` 2007f, which is unmaintained and has known parser CVEs. `redis` (session handlers patched for `zend_string*`) and `xdebug` 3.5.3 (version gates + profiler patch) work on 8.6.
- **Extension Defaults**: `configure-mamp-ini.py` enables every shared extension whose `.so` exists. xdebug is the exception — its `zend_extension` line is generated commented out; enable manually for debugging.
- **Legacy PHP (5.6/7.4)**: Build via `build-legacy-php.sh` from `shivammathur/php-src-backports`; extensions via `build-legacy-ext.sh` (7.4) and `build-legacy-ext56.sh` (5.6). Both link OpenSSL 1.1.1w static and omit gd/sqlite/xsl. imap/mcrypt/pgsql/pdo_pgsql/tidy/yaz/OPcache are the original PHP-API-compatible prebuilt modules (c-client 2007f for imap is insecure). These versions are EOL — never treat them as production-safe or expose them.
- **Configuration Files**: Always use `python3 configure-mamp-ini.py` to regenerate `conf/php.ini`, `conf/pear.conf` (recalculating serialized byte lengths), and `conf/php.ini.temp`. The script skips versions that are not installed.
