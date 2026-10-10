# MAMP 6.9 — Custom PHP Build Scripts

Build scripts and documentation for compiling PHP 8.2.x / 8.3.x / 8.4.x / 8.5.x / 8.6.x from source and installing into MAMP 6.9 on macOS (Apple Silicon and Intel).

MAMP PRO v6.9 no longer ships updated PHP packages — this fills the gap.

## Files

| File | Purpose |
|------|---------|
| `BUILD.md` | Full step-by-step guide |
| `build-php-mamp.sh` | Configure PHP from source (run before `make`) |
| `build-curl-mamp.sh` | Rebuild libcurl against OpenSSL 3 |
| `build-mamp-ext.sh` | Build all C deps + PECL extensions |
| `php8.2.34-arm64.tar.gz` | Pre-built PHP 8.2.34 for Apple Silicon |
| `php8.3.35-arm64.tar.gz` | Pre-built PHP 8.3.35 for Apple Silicon |
| `php8.4.26-arm64.tar.gz` | Pre-built PHP 8.4.26 for Apple Silicon |
| `php8.5.11-arm64.tar.gz` | Pre-built PHP 8.5.11 for Apple Silicon |
| `php8.6.0-arm64.tar.gz` | Pre-built PHP 8.6.0RC3 for Apple Silicon, unpacking to `php8.6.0/` |

### Install directory naming

MAMP Pro enumerates PHP versions by matching the install path against
`^/Applications/MAMP/bin/php/php[578]\.[0-9]\.[0-9]{1,2}/bin$` — the patch component must
be digits only, with no suffix. Pre-releases therefore install under their **numeric**
name: `8.6.0RC3` → `php8.6.0`. A directory named `php8.6.0RC3` works from the command line
but never appears in the MAMP Pro version list.

Newer archives already unpack into `php8.6.0/`. Older ones carry a `php8.6.0RC3/`
top-level directory. Renaming that directory alone is **not** sufficient — the prefix is
baked into `bin/php` and `bin/php-cgi`, so the CLI would load no `php.ini` and
`extension_dir` would point at a missing path. See the fix-up recipe in
[BUILD.md](BUILD.md#install-directory-naming); rebuilding with the current scripts avoids
the problem entirely.

### Pre-built archive naming

Archives are arch-suffixed — binaries are not portable across architectures:

| Suffix | Runs on |
|--------|---------|
| `-arm64` | Apple Silicon (native) |
| `-x86_64` | Intel (native); Apple Silicon via Rosetta 2 |

Intel archives must be built separately on an Intel Mac using the same scripts (arch auto-detected via `uname -m`).

## Quick start

```bash
# 1. Build OpenSSL 3 into MAMP Library (see BUILD.md Step 0)

# 2. Rebuild libcurl against OpenSSL 3
bash build-curl-mamp.sh

# 3. Download PHP source, then configure + make
BUILD="/tmp/php-build-${USER:-mamp}"
mkdir -p "$BUILD"
curl -LO https://www.php.net/distributions/php-8.3.35.tar.gz
tar xzf php-8.3.35.tar.gz -C "$BUILD"
bash build-php-mamp.sh 8.3.35
cd "$BUILD/php-8.3.35" && make -j$(sysctl -n hw.ncpu) && make install

# 4. Build extensions (these are automatically signed ad-hoc on macOS)
bash build-mamp-ext.sh all

# 5. Create conf files (automatically registers config and PECL extensions)
python3 configure-mamp-ini.py
```

See **[BUILD.md](BUILD.md)** for the complete guide including prerequisites, ICU Makefile fix, OpenSSL dylib hiding, conf file generation, macOS code-signing, and all known gotchas.

## Requirements

- macOS 12+ (Apple Silicon or Intel)
- Xcode Command Line Tools
- MAMP 6.9 installed at `/Applications/MAMP`
- MacPorts (recommended package manager and best basis for building — also supplies modern `config.sub` for libmcrypt)
  ```bash
  sudo port install pkgconfig autoconf automake libtool openssl3 libxml2 curl zlib bzip2 libiconv pcre2 libjpeg-turbo libpng freetype webp icu libsodium libmcrypt oniguruma5 libzip
  ```

## Tested

| PHP | Extensions | macOS |
|-----|-----------|-------|
| 8.2.34 | apcu, igbinary, imagick, mcrypt, memcached, oauth, redis, ssh2, tidy, uploadprogress, xdebug, yaml, opcache, pgsql, pdo_pgsql, sysvsem, sysvshm, sysvmsg, shmop | Sequoia 15 (arm64 & x86_64) |
| 8.3.35 | same as above | Sequoia 15 (arm64 & x86_64) |
| 8.4.26 | same as above | Sequoia 15 (arm64 & x86_64) |
| 8.5.11 | same as above (opcache static/built-in; xdebug 3.5.1, oauth 2.0.10, memcached 3.4.0) | Sequoia 15 (arm64 & x86_64) |
| 8.6.0RC3 | supported via `build-php-mamp.sh 8.6.0RC3` & `build-mamp-ext.sh ext86` | Sequoia 15 (arm64 & x86_64) |

Extensions marked as "disabled by default": mcrypt, ssh2, uploadprogress, yaml, sysvsem, sysvshm, sysvmsg, shmop — present as `.so` files, commented out in `php.ini` / `php.ini.temp`. Enable manually when needed.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

