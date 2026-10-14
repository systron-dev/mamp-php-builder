# AI Agent Guidelines & Context

This repository contains build scripts and documentation for compiling custom PHP builds for MAMP 6.9 on macOS (Apple Silicon and Intel).

## Key Environment & Architectural Constraints

- **MAMP 6.9.1 Self-Contained Requirement**: All runtime libraries must live strictly in `/Applications/MAMP/Library` (`$MAMPLIB`). Never introduce runtime dependencies on Homebrew (`/opt/homebrew` or `/usr/local`) or MacPorts (`/opt/local`).
- **MacPorts Build Basis**: MacPorts is the recommended package manager used during build time for tools and headers.
- **OpenSSL 3 Static Linking**: MAMP ships OpenSSL 1.0.2u. OpenSSL 3 static libraries (`libssl.a`, `libcrypto.a`) are installed in `/Applications/MAMP/Library`. Whenever linking against OpenSSL, dynamic symlinks (`libssl.dylib`, `libcrypto.dylib`) in MAMP Library must be temporarily hidden to prevent linking against old OpenSSL 1.0.0.
- **`OPENSSL_LIBS`**: Must use `-L$MAMP/lib -lssl -lcrypto` flags instead of direct `.a` paths because PHP configure's `PHP_EVAL_LIBLINE` drops raw `.a` paths.
- **Deployment Target Floor**: Always ensure `MACOSX_DEPLOYMENT_TARGET=12.0` (Monterey floor) for portable binaries across macOS versions.

## Directory Structure & Version Naming

- **Install Path Convention**: MAMP Pro GUI searches directories matching:
  `^/Applications/MAMP/bin/php/php[578]\.[0-9]\.[0-9]{1,2}/bin$`
- **Pre-releases**: Pre-releases (such as `8.6.0RC3`) must be installed under their numeric name (e.g. `php8.6.0`). The scripts (`build-php-mamp.sh`, `compile-all-php.sh`, `package-mamp-php.sh`) automatically handle this suffix stripping.
- **MAMP PRO GUI Compatibility Limit**: Versions `>= 8.5.0` are filtered out by MAMP PRO v6.x GUI dropdown due to internal hardcoded version checks, but work fully for CLI and custom Apache/CGI setups.

## PHP 8.5 & 8.6 Specifics

- **OPcache**: Compiled statically into PHP core for 8.5+ and 8.6. `opcache.so` does not exist. Do not load `zend_extension=...opcache.so` dynamically in `conf/php.ini`.
- **PHP 8.6 FreeType / GD**: Requires `-DHAVE_FT2BUILD_H` in `FREETYPE2_CFLAGS` and `#define HAVE_FT2BUILD_H 1` in `main/php_config.h`.
- **PHP 8.6 WebP**: Requires `libwebpdemux` and `libwebpmux` in `WEBP_LIBS`.
- **PHP 8.6 PECL Extensions**: Run via `bash build-mamp-ext.sh ext86`. Several upstream extensions (`xdebug`, `apcu`, `imagick`, `memcached`, `oauth`, `redis`, `uploadprogress`, `yaml`, `mcrypt`) currently have upstream API or build incompatibilities with 8.6. `igbinary`, `ssh2`, `tidy`, `pgsql`, `pdo_pgsql`, and System V IPC extensions compile cleanly.
- **Configuration Files**: Always use `python3 configure-mamp-ini.py` to regenerate `conf/php.ini`, `conf/pear.conf` (recalculating serialized byte lengths), and `conf/php.ini.temp`.
