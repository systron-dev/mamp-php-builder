# MAMP 6.9 — Custom PHP Build Scripts

Build scripts and documentation for compiling PHP 8.2.x / 8.3.x / 8.4.x / 8.5.x / 8.6.x from source and installing into MAMP 6.9 on macOS (Apple Silicon and Intel).

MAMP PRO v6.9 no longer ships updated PHP packages — this fills the gap.

## Files

| File | Purpose |
|------|---------|
| `AGENTS.md` | Guidelines, rules, and context for AI coding agents |
| `BUILD.md` | Full step-by-step guide |
| `BUILD-NOTES.md` | Build history, lessons learned, dependency audit |
| `build-php-mamp.sh` | Configure PHP from source (run before `make`) |
| `build-mamp-ext.sh` | Build all C deps + PECL extensions |
| `build-zlib-mamp.sh` | Build zlib 1.3.2 into MAMP Library |
| `build-deps-mamp.sh` | Phase A library modernization (OpenSSL, curl, ICU-independent libs) |
| `build-legacy-php.sh` | Build EOL PHP 5.6 / 7.4 from security-backport branches |
| `build-legacy-ext.sh` | Rebuild PECL extensions for PHP 7.4 |
| `build-legacy-ext56.sh` | Rebuild PECL extensions for PHP 5.6 |
| `build-curl-mamp.sh` | Legacy single-library libcurl rebuild (superseded by `build-deps-mamp.sh`) |
| `compile-all-php.sh` | Orchestration script to configure, compile, and install multiple PHP versions |
| `configure-mamp-ini.py` | Generate and inject `php.ini`, `pear.conf`, and `php.ini.temp` |
| `package-mamp-php.sh` | Package builds into `dist/` tarballs with correct architecture suffix |
| `dist/` | Pre-built archives for Apple Silicon (`arm64`) and Intel (`x86_64`) |

### Install directory naming

MAMP Pro enumerates PHP versions by matching the install path against
`^/Applications/MAMP/bin/php/php[578]\.[0-9]\.[0-9]{1,2}/bin$` — the patch component must
be digits only, with no suffix. Pre-releases therefore install under their **numeric**
name: `8.6.0RC4` → `php8.6.0`. A directory named `php8.6.0RC4` works from the command line
but never appears in the MAMP Pro version list.

Newer archives already unpack into `php8.6.0/`. Older ones carry a suffixed
top-level directory (e.g. `php8.6.0RC4/`). Renaming that directory alone is **not**
sufficient — the prefix is baked into `bin/php` and `bin/php-cgi`, so the CLI would
load no `php.ini` and `extension_dir` would point at a missing path. See the fix-up
recipe in [BUILD.md](BUILD.md#install-directory-naming); rebuilding with the current
scripts avoids the problem entirely.

### Pre-built archive naming

Archives are arch-suffixed — binaries are not portable across architectures:

| Suffix | Runs on |
|--------|---------|
| `-arm64` | Apple Silicon (native) |
| `-x86_64` | Intel (native); Apple Silicon via Rosetta 2 |

Intel archives must be built separately on an Intel Mac using the same scripts. The
scripts always build **native only** — `arm64` on Apple Silicon, `x86_64` on Intel — by
detecting the hardware (`hw.optional.arm64`), not the process architecture. Running a
build from a Rosetta 2 shell therefore still produces an `arm64` build on Apple Silicon;
universal binaries are not produced. `lib-arch.sh` also refuses prebuilt OpenSSL/zlib/curl static libraries and
installed PHP binaries belonging to the other architecture, so the common
mixed-tree mistakes fail fast; other libraries are caught at link time.

## Quick start

```bash
# 1. Modernize MAMP Library (once per dependency refresh)
bash build-zlib-mamp.sh                 # zlib 1.3.2
bash build-deps-mamp.sh all             # OpenSSL 3.6.5 static, curl 8.23, etc.

# 2. Compile + install all target PHP versions
./compile-all-php.sh

# 3. Build extensions (C deps are built once, then PECL for 8.2-8.5 and 8.6)
bash build-mamp-ext.sh deps
bash build-mamp-ext.sh ext
bash build-mamp-ext.sh ext86

# 4. Generate conf files (auto-enables every installed shared extension)
python3 configure-mamp-ini.py

# 5. Optional: package tarballs
./package-mamp-php.sh
```

See **[BUILD.md](BUILD.md)** for the complete guide including prerequisites, dependency build order, ICU Makefile fix, OpenSSL dylib hiding, conf file generation, macOS code-signing, and all known gotchas.

## Requirements

- macOS 12+ (Apple Silicon or Intel)
- Xcode Command Line Tools
- MAMP 6.9 installed at `/Applications/MAMP`
- MacPorts — build-time tools only; no MacPorts library is linked into the result
  ```bash
  sudo port install pkgconfig autoconf automake libtool cmake gettext wget git bison re2c
  ```
  `cmake` is also bootstrapped automatically by `build-mamp-ext.sh` / `build-deps-mamp.sh`
  when missing. All linked libraries (OpenSSL, curl, zlib, ICU, etc.) are either shipped
  in MAMP Library or built from source by these scripts.

## Build environment

**Minimum OS:** macOS 12.0 (Monterey) — every artifact targets
`MACOSX_DEPLOYMENT_TARGET=12.0`, so they run on macOS 12 and newer. Verified with
`otool -l`: `minos 12.0` on `bin/php`, `bin/php-cgi` and every bundled `.so`. The `sdk`
component is higher (27.0 on the current host) — that is the SDK used to compile, not the
minimum required runtime.

Host environments used for builds in this repo:

| Item | Apple Silicon (`arm64`) | Intel (`x86_64`) |
|------|-------------------------|------------------|
| Hardware | Apple Silicon host | Mac mini 6-core Intel |
| macOS | 27.0.1 (build 26A434) | macOS Sequoia 15 (15.8.1, build 24H32) |
| Darwin kernel | 27.0.0 | 24.6.0 |
| Architecture | arm64 | x86_64 |
| SDK | 27.0 | macOS 15.5 SDK / CLT |
| Deployment target | 12.0 | 12.0 |
| MAMP | 6.9 at `/Applications/MAMP` | 6.9 at `/Applications/MAMP` |

Override the target when building for an older floor, e.g. `MACOSX_DEPLOYMENT_TARGET=13.0 bash build-php-mamp.sh 8.5.12` — all build scripts read it, defaulting to `12.0`.

The latest `x86_64` artifacts were built on a Mac mini 6-core Intel running macOS Sequoia 15 (15.8.1). They carry the same `minos 12.0` deployment target.

## Tested

| PHP | Extensions | Runs on |
|-----|-----------|---------|
| 8.2.35 | apcu, igbinary, imagick, mcrypt, memcached, oauth, redis, ssh2, tidy, uploadprogress, xdebug, yaml, opcache, pgsql, pdo_pgsql, sysvsem, sysvshm, sysvmsg, shmop | macOS 12.0+ (arm64 & x86_64) |
| 8.3.36 | same as above | macOS 12.0+ (arm64 & x86_64) |
| 8.4.27 | same as above | macOS 12.0+ (arm64 & x86_64) |
| 8.5.12 | same as above (opcache static/built-in; xdebug 3.5.3, oauth 2.0.10, memcached 3.4.0) | macOS 12.0+ (arm64 & x86_64) |
| 8.6.0RC4 | apcu, igbinary, imagick, mcrypt, memcached, oauth, redis, ssh2, tidy, uploadprogress, xdebug, yaml, opcache (static), pgsql, pdo_pgsql, sysvsem, sysvshm, sysvmsg, shmop (via `ext86`; imap excluded for security) | macOS 12.0+ (arm64 & x86_64) |

> [!NOTE]
> **MAMP PRO GUI Compatibility:** PHP versions `>= 8.5.0` are filtered out by the legacy MAMP PRO v6.x GUI dropdown due to internal app version checks. However, PHP 8.5.x and 8.6.x remain fully functional for CLI usage, custom virtual hosts, and custom Apache/CGI setups.

`configure-mamp-ini.py` enables every shared extension it finds in the version's extension
directory. **xdebug is the exception** — its `zend_extension` line is written commented out to
avoid slowing every CLI call; uncomment it when debugging.

## Legacy builds (PHP 5.6 / 7.4)

`build-legacy-php.sh` builds EOL PHP from community security-backport branches
(`shivammathur/php-src-backports`), which include the CVE-2026-109618/109619 fixes:

| Version | Source branch | Extensions |
|---|---|---|
| 5.6.40 | `PHP-5.6-security-backports-openssl11` | apcu, igbinary, imagick, imap*, mcrypt*, memcached, oauth, pgsql*, pdo_pgsql*, redis, tidy*, uploadprogress, yaml, yaz*, OPcache (compatible prebuilt modules marked *) |
| 7.4.33 | `PHP-7.4-security-backports` | apcu, igbinary, imagick, imap*, mcrypt, memcached, oauth, pgsql*, pdo_pgsql*, redis, ssh2, uploadprogress, yaml, yaz*, sysv*, OPcache (prebuilt marked *) |

Both link **OpenSSL 1.1.1w static** (legacy PHP cannot use OpenSSL 3). Deliberately
omitted: `gd`, `sqlite3`/`pdo_sqlite`, `xsl` (incompatible with current MAMP libs).
`imap` uses the legacy c-client 2007f module and is insecure; enable only when needed.
Both backport branches include the CVE-2023-0662 multipart DoS fix; `php.ini` pins
`max_multipart_body_parts = 1000` (upstream default is unlimited).

> [!WARNING]
> Both versions are end-of-life. The backports cover known CVEs only. OpenSSL 1.1.1w
> ended support in September 2023 and has no further security fixes. Do not expose
> these builds to untrusted networks.

## Security

All five packaged builds — PHP 8.2.35, 8.3.36, 8.4.27, 8.5.12, and 8.6.0RC4 — contain the
patches for **[CVE-2026-109618](https://www.cve.org/CVERecord?id=CVE-2026-109618)** (OOM corruption in mod_php/FPM) and **[CVE-2026-109619](https://www.cve.org/CVERecord?id=CVE-2026-109619)**
(stale global state), both CVSS v4.0 9.2 and fixed upstream on 2026-10-21. Confirmed in the
`NEWS` file of each php-src tag (`php-8.2.35`, `php-8.3.36`, `php-8.4.27`, `php-8.5.12`,
`php-8.6.0RC4`). Run one of these builds; older 8.2–8.6 targets in `dist/` do not include
the fixes.

`imap` is not shipped: PHP removed it from core in 8.4, and PECL `imap` depends on UW
`c-client` 2007f — unmaintained since 2007 with known parser CVEs.

## Runtime libraries

MAMP ships 2016-era libraries. All PHP 8.x builds now link the modernized set below
(phase A). ICU 56.1 and libxml2 2.9.4 remain until phase B, which requires a separate
legacy prefix for PHP 5.6/7.4.

| Library | Version | Notes |
|---|---|---|
| zlib | 1.3.2 | `build-zlib-mamp.sh` |
| OpenSSL | 3.6.5 | static only; MAMP's dynamic 1.0.0 retained |
| nghttp2 | 1.70.0 | |
| curl | 8.23.0 | |
| libpng | 1.6.59 | |
| freetype | 2.15.0 | |
| libzip | 1.12 | |
| tidy | 5.8.0 | `libtidy.58`, compat `libtidy.5` symlink |
| libsodium | 1.0.22 | `libsodium.26`, compat `libsodium.23` symlink for legacy PHP 7.4 |
| libwebp | 1.6.0 | |
| oniguruma | 6.9.10 | |
| ImageMagick delegates | jbig 2.2, libjxl 0.12, djvulibre 3.5.30, brotli 1.2.1, highway 1.4.0 | static, bundled into imagick.so |
| ICU | 56.1 | phase B |
| libxml2 | 2.9.4 | phase B |
| libxslt | 1.1.28 | phase B (1.1.45 needs libxml2 ≥ 2.15.1) |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

