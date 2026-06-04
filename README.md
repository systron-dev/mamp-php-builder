# MAMP 6.9 — Custom PHP Build Scripts

Build scripts and documentation for compiling PHP 8.2.x / 8.3.x / 8.4.x / 8.5.x from source and installing into MAMP 6.9 on macOS (Apple Silicon and Intel).

MAMP PRO v6.9 no longer ships updated PHP packages — this fills the gap.

## Files

| File | Purpose |
|------|---------|
| `BUILD.md` | Full step-by-step guide |
| `build-php-mamp.sh` | Configure PHP from source (run before `make`) |
| `build-curl-mamp.sh` | Rebuild libcurl against OpenSSL 3 |
| `build-mamp-ext.sh` | Build all C deps + PECL extensions |
| `php8.2.31-arm64.tar.gz` | Pre-built PHP 8.2.31 for Apple Silicon |
| `php8.3.31-arm64.tar.gz` | Pre-built PHP 8.3.31 for Apple Silicon |
| `php8.4.21-arm64.tar.gz` | Pre-built PHP 8.4.21 for Apple Silicon |
| `php8.5.6-arm64.tar.gz` | Pre-built PHP 8.5.6 for Apple Silicon |

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
curl -LO https://www.php.net/distributions/php-8.3.31.tar.gz
tar xzf php-8.3.31.tar.gz -C /tmp/php-build/
bash build-php-mamp.sh 8.3.31
cd /tmp/php-build/php-8.3.31 && make -j$(sysctl -n hw.ncpu) && make install

# 4. Build extensions
bash build-mamp-ext.sh all

# 5. Create conf files (see BUILD.md Step 4)
```

See **[BUILD.md](BUILD.md)** for the complete guide including prerequisites, ICU Makefile fix, OpenSSL dylib hiding, conf file generation, and all known gotchas.

## Requirements

- macOS 12+ (Apple Silicon or Intel)
- Xcode Command Line Tools
- MAMP 6.9 installed at `/Applications/MAMP`
- MacPorts (for libmcrypt build only — supplies modern `config.sub`)

## Tested

| PHP | Extensions | macOS |
|-----|-----------|-------|
| 8.2.31 | apcu, igbinary, imagick, mcrypt, memcached, oauth, redis, ssh2, tidy, uploadprogress, xdebug, yaml, opcache, pgsql, pdo_pgsql, sysvsem, sysvshm, sysvmsg, shmop | Sequoia 15 arm64 |
| 8.3.31 | same as above | Sequoia 15 arm64 |
| 8.4.21 | same as above | Sequoia 15 arm64 |
| 8.5.6  | same as above (opcache static/built-in; xdebug 3.5.1, oauth 2.0.10, memcached 3.4.0) | Sequoia 15 arm64 |

Extensions marked as "disabled by default": mcrypt, ssh2, uploadprogress, yaml, sysvsem, sysvshm, sysvmsg, shmop — present as `.so` files, commented out in `php.ini` / `php.ini.temp`. Enable manually when needed.
