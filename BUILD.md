# Building Custom PHP Versions for MAMP 6.9

MAMP PRO v6.9 no longer ships newer PHP packages — updates are v7.x-only. This guide covers building PHP from source and installing it into MAMP's directory structure on both Apple Silicon (arm64) and Intel (x86_64).

**Minimum OS:** macOS 12.0 (Monterey). Every artifact is compiled with `MACOSX_DEPLOYMENT_TARGET=12.0`, so the result runs on macOS 12 and newer. The SDK used to compile is newer (27.0 on the machine used for these builds) — SDK version is not the runtime requirement.

**Target versions (rebuild required):** PHP 8.2.35, PHP 8.3.36, PHP 8.4.27, PHP 8.5.12, PHP 8.6.0RC4 on MAMP v6.9, macOS 12 (Monterey) and newer (arm64 and x86_64); built on macOS 27.0.1 / SDK 27.0 (arm64 host)

### Environment variables

Run this first in every shell session before following this guide:

```bash
ARCH=$(uname -m)                     # arm64 on Apple Silicon, x86_64 on Intel
BUILD="/tmp/php-build-${USER:-mamp}" # Build workspace directory
```

All commands below use these variables.

---

## Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Step 0 — Build OpenSSL 3](#step-0--build-openssl-3)
4. [Step 1 — Modernize MAMP's shared libraries](#step-1--modernize-mamps-shared-libraries)
5. [Step 2 — Build PHP](#step-2--build-php)
6. [Step 3 — Build PHP Extensions](#step-3--build-php-extensions)
7. [Step 4 — Install Conf Files](#step-4--install-conf-files)
8. [Legacy builds — PHP 5.6 and 7.4](#legacy-builds--php-56-and-74)
9. [Verification](#verification)
10. [Adding Another PHP Version](#adding-another-php-version)
11. [Known Issues & Gotchas](#known-issues--gotchas)

---

## Overview

### Constraint: fully self-contained in `/Applications/MAMP/Library`

MAMP runs as a bundled app. All libraries must live inside `/Applications/MAMP/Library` — no Homebrew or MacPorts paths at runtime. Every dependency is either already present in MAMP Library or built from source and installed there (or into `$BUILD/ext-deps/` for extension-only deps).

### Directory layout

```
/Applications/MAMP/Library/          MAMP's own lib/include/bin (MAMPLIB)
/Applications/MAMP/bin/php/          PHP installations
  php8.2.35/
    bin/php, phpize, php-config
    conf/php.ini, pear.conf, php.ini.temp
    lib/php/extensions/no-debug-non-zts-20220829/
  php8.3.36/
    ...extensions/no-debug-non-zts-20230831/
  php8.4.27/
    ...extensions/no-debug-non-zts-20240924/
  php8.5.12/
    ...extensions/no-debug-non-zts-20250925/
  php8.6.0/                    (PHP 8.6.0RC4 — pre-releases install under numeric name)
    ...extensions/no-debug-non-zts-20260924/
/tmp/php-build-${USER:-mamp}/         build workspace ($BUILD)
  build-php-mamp.sh                  PHP configure script
  build-mamp-ext.sh                  extension build script
  build-zlib-mamp.sh                 zlib upgrade script
  build-deps-mamp.sh                 phase A library modernization script
  ext-deps/                          static C libs for extensions
  ext-src/                           unpacked extension source trees
  deps-phase-a/                      phase A sources, staging, backups
```

### PHP API extension dir hashes

| PHP version | Extension dir hash         |
|-------------|----------------------------|
| 8.2.x       | no-debug-non-zts-20220829  |
| 8.3.x       | no-debug-non-zts-20230831  |
| 8.4.x       | no-debug-non-zts-20240924  |
| 8.5.x       | no-debug-non-zts-20250925  |
| 8.6.x       | no-debug-non-zts-20260924  |

---

## Security baseline

The current target set is the 2026-10-21 security release. All of
`8.2.35`, `8.3.36`, `8.4.27`, `8.5.12` and `8.6.0RC4` contain the fixes for:

- **[CVE-2026-109618](https://www.cve.org/CVERecord?id=CVE-2026-109618)** — OOM corruption in mod_php/FPM
- **[CVE-2026-109619](https://www.cve.org/CVERecord?id=CVE-2026-109619)** — stale global state

Both are CVSS v4.0 9.2. Upstream confirmation: the `NEWS` file in each php-src tag lists
the CVEs (`php-8.6.0RC3` does not). Do not package older 8.2–8.6 targets.

## Prerequisites

### macOS version
macOS 12.0 (Monterey) or newer, on Apple Silicon (arm64) or Intel (x86_64). The build scripts default `MACOSX_DEPLOYMENT_TARGET` to `12.0`; raise it only if you deliberately want a higher floor. See [macOS OS Version Backward Compatibility](#macos-os-version-backward-compatibility).

### Xcode Command Line Tools
```bash
xcode-select --install
```

### MacPorts (build-time tools only)
MacPorts supplies the build tools. No MacPorts library is linked into the result.
```bash
sudo port install pkgconfig autoconf libtool gettext wget git
```
`cmake` is bootstrapped automatically into `$BUILD/cmake-bin` when missing. All linked
libraries are shipped by MAMP or built from source by the scripts in this repo.

It is also used to supply a modern `config.sub`/`config.guess` when building libmcrypt:
```bash
# Check it exists — only needed if building mcrypt extension
ls /opt/local/share/libtool/build-aux/config.sub
```

### Download PHP source
```bash
mkdir -p "$BUILD"
cd "$BUILD"
curl -LO https://www.php.net/distributions/php-8.2.35.tar.gz
curl -LO https://www.php.net/distributions/php-8.3.36.tar.gz
curl -LO https://www.php.net/distributions/php-8.4.27.tar.gz
curl -LO https://www.php.net/distributions/php-8.5.12.tar.gz
# For pre-releases / RCs (e.g. PHP 8.6.0RC4 from QA or GitHub php-src):
# curl -LO https://downloads.php.net/~mbeccati/php-8.6.0RC4.tar.gz
tar xzf php-8.2.35.tar.gz
tar xzf php-8.3.36.tar.gz
tar xzf php-8.4.27.tar.gz
tar xzf php-8.5.12.tar.gz
# tar xzf php-8.6.0RC4.tar.gz
# Note: build-php-mamp.sh automatically handles downloading/extracting 8.6 pre-releases if not present.
```

---

## Step 0 — Build OpenSSL 3

MAMP ships OpenSSL 1.0.2u — too old for PHP 8.3+. Build OpenSSL 3.6.5 static libs into MAMP Library.

The supported path is `build-deps-mamp.sh openssl`, which downloads, checksum-verifies, and
installs the static libraries and headers without touching MAMP's dynamic 1.0.0 libraries:

```bash
bash build-deps-mamp.sh openssl
```

Manual equivalent:

```bash
cd "$BUILD"
curl -LO https://www.openssl.org/source/openssl-3.6.5.tar.gz
tar xzf openssl-3.6.5.tar.gz
cd openssl-3.6.5

./Configure no-shared no-tests \
  --prefix=/Applications/MAMP/Library \
  --openssldir=/Applications/MAMP/Library/openssl \
  darwin64-${ARCH}-cc     # arm64 → darwin64-arm64-cc | x86_64 → darwin64-x86_64-cc

make -j$(sysctl -n hw.ncpu) build_libs
# install libssl.a / libcrypto.a + include/openssl only
```

Verify:
```bash
grep OPENSSL_VERSION_TEXT /Applications/MAMP/Library/include/openssl/opensslv.h
# should say OpenSSL 3.6.5
ls /Applications/MAMP/Library/lib/libssl.a   # must exist
```

> **Why static (`no-shared`)?** MAMP already has `libssl.dylib`/`libcrypto.dylib` pointing to old 1.0. During `make` for PHP and libcurl those symlinks must be hidden so the linker finds only the `.a` files. All build scripts handle this automatically.

---

## Step 1 — Modernize MAMP's shared libraries

MAMP's bundled libraries are partly from 2016. Phase A upgrades the ABI-compatible set:

```bash
bash build-zlib-mamp.sh          # zlib 1.3.2
bash build-deps-mamp.sh all      # OpenSSL 3.6.5, nghttp2 1.70, curl 8.23, libpng 1.6.59,
                                 # freetype 2.15, libzip 1.12, tidy 5.8, libsodium 1.0.22,
                                 # webp 1.6, oniguruma 6.9.10
```

Each library is downloaded from its upstream release, verified against the MacPorts
portfile SHA-256, built with `-mmacosx-version-min=12.0`, staged, then installed into
`/Applications/MAMP/Library` with the previous files moved to
`$BUILD/deps-phase-a/backup`.

`libxslt` is intentionally deferred: 1.1.45 requires libxml2 ≥ 2.15.1, and libxml2 ≥ 2.12
breaks PHP 5.6/7.4. It belongs to phase B together with ICU 78, readline 8.3,
libjpeg-turbo and OpenLDAP 2.6.

> **Important:** after this step, rebuild PHP (`./compile-all-php.sh`). The libsodium
> soname changes from 23 to 26 and old PHP binaries will not start until rebuilt. A
> `libsodium.23.dylib` symlink is kept so the legacy `php7.4.33` install still runs.

---

## Legacy builds — PHP 5.6 and 7.4

EOL versions are built from `shivammathur/php-src-backports` (community security
backports, including CVE-2026-109618/109619) with a private OpenSSL 1.1.1w prefix:

```bash
bash build-legacy-php.sh 7.4      # PHP 7.4.33
bash build-legacy-php.sh 5.6      # PHP 5.6.40
bash build-legacy-ext.sh          # 7.4 extensions
bash build-legacy-ext56.sh        # 5.6 extensions
```

Key differences from the 8.x builds:

- OpenSSL **1.1.1w static** in `$BUILD/legacy-deps`; PHP 5.6/7.4 cannot use OpenSSL 3.
- Private static **libxml2 2.9.14** — MAMP's copy hides `xmlXPathValuePop/Push`.
- C standard forced: `gnu89` (5.6), `gnu11` (7.4); Xcode 21 clang defaults to C23.
- 5.6: bundled oniguruma (MAMP header hidden during build), tidy disabled (`buffio.h`
  missing in tidy 5.8), OPcache disabled at build time.
- 7.4: xsl objects/libs stripped from the Makefile (same libxml2 issue).
- Rebuilt extensions: apcu, igbinary, imagick, memcached, oauth, redis,
  uploadprogress, yaml, xdebug (7.4 also mcrypt/ssh2/sysv).
- Compatible prebuilt modules retained: imap, mcrypt (5.6), pgsql, pdo_pgsql, tidy,
  yaz, OPcache. `imap` depends on c-client 2007f and is insecure.
- Omitted: gd, sqlite3/pdo_sqlite, xsl (incompatible with current MAMP libs).

> **Warning:** PHP 5.6/7.4 are end-of-life, and OpenSSL 1.1.1w ended support in
> September 2023. These builds cover known CVEs only — do not expose them.

## Step 2 — Build PHP

### Run configure

```bash
bash "$BUILD/build-php-mamp.sh" 8.2.35
# or
bash "$BUILD/build-php-mamp.sh" 8.3.36
# or
bash "$BUILD/build-php-mamp.sh" 8.4.27
# or
bash "$BUILD/build-php-mamp.sh" 8.5.12
# or (for RC / pre-releases)
bash "$BUILD/build-php-mamp.sh" 8.6.0RC4
```

The script runs `./configure` only — it does **not** run `make`.

### Install directory naming

MAMP Pro discovers PHP versions by matching the install path against
`^/Applications/MAMP/bin/php/php[578]\.[0-9]\.[0-9]{1,2}/bin$` — the patch component
must be digits only, with no suffix. A pre-release therefore installs under its numeric
name: `8.6.0RC4` → `php8.6.0`. Installing as `php8.6.0RC4` leaves it invisible in the
MAMP Pro GUI even though the binary works from the command line.

`build-php-mamp.sh` and `compile-all-php.sh` strip the suffix automatically for the
install prefix while keeping the full version string for the source tarball and build
directory.

**Existing installs and archives created before this change** need manual fixing. Renaming
the directory is *not* enough on its own: the install prefix is baked into `bin/php` and
`bin/php-cgi` (`PHP_CONFIG_FILE_PATH`, `extension_dir`, PEAR paths), so a bare rename leaves
the CLI loading no `php.ini`.

```bash
cd /Applications/MAMP/bin/php
mv php8.6.0RC4 php8.6.0
ln -sfn php8.6.0 php8.6.0RC4          # keeps the baked-in paths resolvable
cd php8.6.0
for f in bin/phpize bin/php-config include/php/main/build-defs.h \
         include/php/main/php_version.h php/man/man1/*.1 \
         conf/php.ini conf/php.ini.temp; do
  [ -f "$f" ] && perl -pi -e 's/8\.6\.0RC3/8.6.0/g' "$f"
done
```

Do **not** run a blanket find/replace over the tree — `conf/pear.conf` stores paths inside
serialized strings with explicit `s:N:"…"` lengths, and the binaries must not be rewritten.
Regenerate the conf files instead, which handles both:

```bash
python3 configure-mamp-ini.py        # writes php8.6.0/conf with correct lengths
```

The clean fix is a rebuild — the symlink above is only a stopgap.

**What it sets up:**
- All pkg-config overrides to point at MAMP Library (no external paths)
- Hides OpenSSL dylib symlinks via a trap (restored on exit)
- Version-specific flags: PHP 8.4+ removed `--with-zlib-dir` and `--with-kerberos`
- `OPENSSL_LIBS="-L$MAMP/lib -lssl -lcrypto"` — uses `-L/-l` flags because `PHP_EVAL_LIBLINE` silently drops full `.a` paths

### Fix Makefile for PHP 8.3 (ICU)

MAMP has ICU 56 with versioned symbols (`u_sprintf_56` in `libicuio`). PHP 8.3 needs explicit `-licuio` appended to `EXTRA_LIBS`. PHP 8.2 and 8.4+ pick it up automatically from the configure environment.

```bash
# PHP 8.3 only:
python3 -c "
import re
f = '${BUILD}/php-8.3.36/Makefile'
c = open(f).read()
open(f, 'w').write(re.sub(r'^(EXTRA_LIBS = .+)$', r'\1 -licuio', c, flags=re.MULTILINE))
"
```

### Run make

```bash
cd "$BUILD/php-8.3.36"    # or php-8.4.27

MAMP=/Applications/MAMP/Library
mv $MAMP/lib/libssl.dylib $MAMP/lib/libssl.dylib.hidden
mv $MAMP/lib/libcrypto.dylib $MAMP/lib/libcrypto.dylib.hidden

make -j$(sysctl -n hw.ncpu) 2>&1 | tee /tmp/make-php.log

mv $MAMP/lib/libssl.dylib.hidden $MAMP/lib/libssl.dylib
mv $MAMP/lib/libcrypto.dylib.hidden $MAMP/lib/libcrypto.dylib
```

### Install

```bash
make install
```

### Copy libphp.so (Apache module)

MAMP GUI requires the Apache PHP module (`libphp.so`) to be located inside each individual PHP version's folder under `modules/libphp.so` to recognize it as a valid, web-enabled version. When you switch versions in the GUI, MAMP copies it to the global directory automatically.

```bash
# 1. Create the modules folder inside the PHP directory and copy it
mkdir -p /Applications/MAMP/bin/php/php8.3.36/modules
cp "$BUILD/php-8.3.36/libs/libphp.so" /Applications/MAMP/bin/php/php8.3.36/modules/libphp.so
codesign --force --sign - /Applications/MAMP/bin/php/php8.3.36/modules/libphp.so

# 2. Also copy to MAMP's global Apache modules directory as a fallback
cp "$BUILD/php-8.3.36/libs/libphp.so" /Applications/MAMP/Library/modules/libphp.so
codesign --force --sign - /Applications/MAMP/Library/modules/libphp.so
```

---

## Step 3 — Build PHP Extensions

### Run all (C deps + PECL extensions)

```bash
bash "$BUILD/build-mamp-ext.sh" all
```

Or build phases separately:

```bash
bash "$BUILD/build-mamp-ext.sh" deps    # C libraries only
bash "$BUILD/build-mamp-ext.sh" ext     # PECL extensions for 8.2 + 8.3 + 8.4 + 8.5
bash "$BUILD/build-mamp-ext.sh" ext86   # PECL extensions for 8.6 only
```

`ext85` is retained for historical 8.5-only rebuilds; `ext` now applies the same
8.5-compatible extension versions (xdebug 3.5.3, oauth 2.0.10, memcached 3.4.0) to all
of 8.2–8.5.

Or individual targets:

```bash
bash "$BUILD/build-mamp-ext.sh" imagick
bash "$BUILD/build-mamp-ext.sh" memcached
bash "$BUILD/build-mamp-ext.sh" pgsql
bash "$BUILD/build-mamp-ext.sh" sysv    # sysvsem + sysvshm + sysvmsg + shmop
```

### C library dependencies built (to `$BUILD/ext-deps/`)

| Library              | Version  | Notes                                            |
|----------------------|----------|--------------------------------------------------|
| libyaml              | 0.2.5    |                                                  |
| libssh2              | 1.11.1   | Built against MAMP OpenSSL 3 static              |
| libmcrypt            | 2.5.8    | Needs MacPorts `config.sub`; C89 flags required  |
| libmemcached-awesome | 1.1.4    | cmake build                                      |
| libpq (PostgreSQL)   | 16.3     | Static `.a` only — dylib atexit check fails      |
| libjpeg-turbo        | 3.0.3    | cmake build                                      |
| libpng               | 1.6.43   |                                                  |
| libtiff              | 4.6.0    |                                                  |
| libwebp              | 1.4.0    |                                                  |
| jbigkit              | 2.2      | ImageMagick JBIG delegate                         |
| brotli               | 1.2.1    | libjxl dependency                                 |
| highway              | 1.4.0    | libjxl dependency                                 |
| libjxl               | 0.12.0   | JPEG XL; skcms vendored into third_party          |
| djvulibre            | 3.5.30   | ImageMagick DjVu delegate                         |
| freetype             | 2.13.2   |                                                  |
| ImageMagick          | 7.1.1-33 | Depends on all image libs above                  |
| libyaz               | 5.34.0   | **SKIPPED** — libxml2/libxslt dep issues         |

### PHP extensions built

| Extension      | 8.2.35 | 8.3.36 | 8.4.27 | 8.5.12  | 8.6.0   | Notes                                              |
|----------------|--------|--------|--------|---------|---------|----------------------------------------------------|
| apcu           | ✓      | ✓      | ✓      | ✓       | ✓       | 8.6: `php_verror()` patch + compat header          |
| igbinary       | ✓      | ✓      | ✓      | ✓       | ✓       | Builds on 8.6 with compat header                   |
| imagick        | ✓      | ✓      | ✓      | ✓       | ✓       | All delegates bundled: jbig, jxl, djvu, png, tiff, webp, freetype |
| mcrypt         | ✓      | ✓      | ✓      | ✓       | ✓       | 8.6: 1.0.9, stream filters removed, `php_rand.h` shim |
| memcached      | ✓ 3.4.0| ✓ 3.4.0| ✓ 3.4.0| ✓ 3.4.0 | ✓ 3.4.0 | 8.6 builds with compat header                      |
| oauth          | ✓ 2.0.10| ✓ 2.0.10| ✓ 2.0.10| ✓ 2.0.10| ✓ 2.0.10| 8.6: `XtOffsetOf` → `offsetof` patch              |
| redis          | ✓      | ✓      | ✓      | ✓       | ✓ 6.3.0 | 8.6: session handlers patched for `zend_string*` args; no igbinary |
| ssh2           | ✓      | ✓      | ✓      | ✓       | ✓       | OpenSSL static symbols; 1.5.0 needs PHP 8.6 API patch            |
| tidy           | ✓      | ✓      | ✓      | ✓       | ✓       | Built shared by the PHP core configure             |
| uploadprogress | ✓      | ✓      | ✓      | ✓       | ✓       | Builds on 8.6 with compat header                   |
| xdebug         | ✓ 3.5.3| ✓ 3.5.3| ✓ 3.5.3| ✓ 3.5.3 | ✓ 3.5.3 | 8.6: version gates widened + profiler patch; disabled by default |
| yaml           | ✓      | ✓      | ✓      | ✓       | ✓       | Builds on 8.6 with compat header                   |
| opcache        | ✓      | ✓      | ✓      | static  | static  | Built into PHP 8.5+ & 8.6 — no .so; comment out ini|
| pgsql          | ✓      | ✓      | ✓      | ✓       | ✓       | Needs `LIBS="-lpq -lssl -lcrypto -lz"`             |
| pdo_pgsql      | ✓      | ✓      | ✓      | ✓       | ✓       | Same as pgsql                                      |
| sysvsem        | ✓      | ✓      | ✓      | ✓       | ✓       | System V semaphores; enabled by default            |
| sysvshm        | ✓      | ✓      | ✓      | ✓       | ✓       | System V shared memory; enabled by default         |
| sysvmsg        | ✓      | ✓      | ✓      | ✓       | ✓       | System V message queues; enabled by default        |
| shmop          | ✓      | ✓      | ✓      | ✓       | ✓       | POSIX shared memory ops; enabled by default        |

**Not built:**
- `imap` — deliberately skipped: removed from core in 8.4; c-client 2007f is unmaintained and unsafe
- `yaz` — libyaz build fails on libxml2/libxslt deps; low priority

`configure-mamp-ini.py` uncomments every `extension=` line whose `.so` exists. The only
exception is **xdebug**: its `zend_extension` line stays commented out by default because
loading it on every CLI call is slow. Uncomment it in `conf/php.ini` when debugging.

---

## Step 4 — Install Conf Files

Three files are needed in `conf/` for each PHP version: `php.ini`, `pear.conf`, and `php.ini.temp`.

### Recommended: Automatic Configuration

We provide a Python script `configure-mamp-ini.py` that automatically generates and configures all three files for all PHP versions (`8.2.x`, `8.3.x`, `8.4.x`, `8.5.x`, and `8.6.x`).

It automatically:
- Creates the missing `conf/` directories.
- Dynamically updates serialized paths and string lengths in `pear.conf`.
- Formats and injects the complete extension policies for live and template configs.
- Comments out deprecated session settings (`session.sid_length = 26` and `session.sid_bits_per_character = 5`) for PHP 8.4+ to prevent startup warnings.
- Disables OPcache dynamic loading in PHP 8.5+ (since it is statically compiled).

To generate configurations for all versions, simply run:
```bash
python3 configure-mamp-ini.py
```

---

### Fallback: Manual File Details

If you wish to configure files manually or understand the underlying logic:

#### php.ini

`make install` creates `conf/php.ini`. Edit it to fix:
- `extension_dir` path (correct version + API hash)
- `zend_extension` paths for opcache and xdebug

##### Extension policy (mirrors MAMP 8.2/8.3 reference defaults)

**Always on** (hardcoded `extension=`):
- `pgsql.so`, `pdo_pgsql.so`
- apcu, igbinary, imagick, memcached, oauth, redis, tidy ← managed by MAMP PRO UI via `MAMP_xxx_MAMP` placeholders in `php.ini.temp`; hardcoded on in the generated live conf

**Commented out** (available, enable manually):
```ini
;extension=imap.so          ; not built — c-client 2007f unmaintained (security)
;extension=mcrypt.so        ; not in MAMP reference defaults
;extension=ssh2.so          ; not in MAMP reference defaults
;extension=uploadprogress.so; disabled in MAMP reference
;extension=yaml.so          ; disabled in MAMP reference
;extension=sysvsem.so       ; System V semaphores
;extension=sysvshm.so       ; System V shared memory
;extension=sysvmsg.so       ; System V message queues
;extension=shmop.so         ; POSIX shared memory ops
```

#### pear.conf

PHP serialized format — string lengths must be recalculated. Use this script:

```python
import re

def update_pear_conf(content, old_ver, new_ver, old_hash=None, new_hash=None):
    def replace_serialized_str(m):
        s = m.group(1)
        new_s = s.replace(old_ver, new_ver)
        if old_hash and new_hash:
            new_s = new_s.replace(old_hash, new_hash)
        if new_s != s:
            return f's:{len(new_s)}:"{new_s}"'
        return m.group(0)
    return re.sub(r's:\d+:"([^"]*)"', replace_serialized_str, content)

# Use closest existing version as base (same minor preferred)
with open('/Applications/MAMP/bin/php/php8.2.0/conf/pear.conf') as f:
    base = f.read()

# Same API hash (same minor version):
result = update_pear_conf(base, 'php8.2.0', 'php8.2.35')

# Different API hash (new minor/major):
# result = update_pear_conf(base, 'php8.2.0', 'php8.3.36',
#     'no-debug-non-zts-20220829', 'no-debug-non-zts-20230831')

with open('/Applications/MAMP/bin/php/php8.3.36/conf/pear.conf', 'w') as f:
    f.write(result)
```

#### php.ini.temp

MAMP PRO's template file (contains `MAMP_xxx_MAMP` placeholders). Copy and substitute:

```python
with open('/Applications/MAMP/bin/php/php8.2.0/conf/php.ini.temp') as f:
    base = f.read()

# Same API hash:
result = base.replace('php8.2.0', 'php8.2.35')

# Different API hash:
# result = base.replace('php8.2.0', 'php8.3.36') \
#              .replace('no-debug-non-zts-20220829', 'no-debug-non-zts-20230831')

with open('/Applications/MAMP/bin/php/php8.3.36/conf/php.ini.temp', 'w') as f:
    f.write(result)
```

The last line of `php.ini.temp` must read:
```
; DONT REMOVE: MAMP PRO php<version>.ini template compatibility version: 16
```

---

## Verification

```bash
# Check PHP binary
/Applications/MAMP/bin/php/php8.3.36/bin/php -v

# Check loaded extensions
/Applications/MAMP/bin/php/php8.3.36/bin/php -m

# Check no external dylib deps (should only show MAMP + system libs)
otool -L /Applications/MAMP/bin/php/php8.3.36/bin/php | grep -v MAMP | grep -v /usr/lib | grep -v /System

# Verify OpenSSL version used
/Applications/MAMP/bin/php/php8.3.36/bin/php -r "echo openssl_get_cipher_methods()[0];"
/Applications/MAMP/bin/php/php8.3.36/bin/php -r "phpinfo();" | grep -i openssl

# Verify the runtime floor (minos = minimum OS required; sdk = SDK used to compile)
otool -l /Applications/MAMP/bin/php/php8.3.36/bin/php | grep -A4 LC_BUILD_VERSION
# expect: platform 1 / minos 12.0 / sdk <host SDK>

# Same check across every bundled extension
for so in /Applications/MAMP/bin/php/php8.3.36/lib/php/extensions/*/*.so; do
  printf "%-25s %s\n" "$(basename "$so")" \
    "$(otool -l "$so" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
done
```

---

## Adding Another PHP Version

1. **Download + extract source** to `"$BUILD/php-X.Y.Z/"`
2. **Check API hash** — run `php -i | grep extension_dir` on an existing build for that minor, or look up the PHP API version constant
3. **Run configure:** `bash "$BUILD/build-php-mamp.sh" X.Y.Z`
5. **Fix Makefile** (PHP 8.3 only — add `-licuio` to `EXTRA_LIBS`)
6. **Hide OpenSSL dylinks, run make, restore**
7. **`make install`**
8. **Copy `libphp.so`** to `/Applications/MAMP/Library/modules/`
9. **Create conf files:** `php.ini` (fix paths), `pear.conf` (Python script), `php.ini.temp` (string replace)
10. **Build extensions:** `bash "$BUILD/build-mamp-ext.sh" all` (re-runs cleanly; already-built C deps are cached)

---

## Known Issues & Gotchas

### Multi-User / Shared Machine Workspace Conflicts

If multiple users run the build scripts on the same machine, building inside `/tmp/php-build` directly causes permission errors due to mismatched file ownership. The scripts resolve this by using a dynamic path: `BUILD="/tmp/php-build-${USER:-mamp}"`.

### macOS Code-Signing (SIGKILL / Exit Code 137)

Compiled `.so` extensions on macOS must be signed ad-hoc to satisfy macOS security policies. If unsigned, loading the extension will trigger a silent crash with `Exit Code 137` (SIGKILL).
* `build-mamp-ext.sh` now automatically runs `codesign --force --sign -` on all built modules.
* If you build or copy a `.so` file manually, sign it using:
  ```bash
  codesign --force --sign - /path/to/extension.so
  ```

### ImageMagick Host Machine Delegate Crashes (Segmentation Fault / Exit Code 139)

If ImageMagick configure auto-detects dynamic libraries from the host system (e.g. Graphviz/`gvc`, `libraw`, `fontconfig`, `pango`) which are not included in the standard MAMP environment, the resulting static ImageMagick library uses dynamic lookup. At runtime, these dynamic symbols resolve to `NULL`, causing `php --info` or `phpinfo()` to crash with a segmentation fault when compiling imagick info.
* **Solution:** Explicitly disable all host-system optional delegates during ImageMagick configure inside `build-mamp-ext.sh` (`--without-gvc`, `--without-raw`, `--without-fontconfig`, `--without-pango`, etc.).

### OpenSSL dylib symlinks must be hidden during `make`

`/Applications/MAMP/Library/lib/libssl.dylib` and `libcrypto.dylib` are symlinks to old OpenSSL 1.0. If present during linking, the linker uses them instead of `libssl.a`/`libcrypto.a` (OpenSSL 3). All build scripts hide and restore these automatically via a trap.

### `OPENSSL_LIBS` must use `-L/-l` flags

`PHP_EVAL_LIBLINE` (used internally by PHP's configure) silently ignores full `.a` paths like `/path/to/libssl.a`. Use `-L$MAMP/lib -lssl -lcrypto` instead.

### PHP 8.3 ICU: explicit `-licuio` required

MAMP's ICU 56 has versioned symbols (`u_sprintf_56`). Without `-licuio` in `EXTRA_LIBS`, the PHP 8.3 link fails. PHP 8.2 and PHP 8.4+ pick it up automatically from the configure environment. Fix: patch Makefile before `make` (PHP 8.3 only).

### PHP 8.4 removed configure flags

`--with-zlib-dir` and `--with-kerberos` were removed. `build-php-mamp.sh` conditionally omits them for PHP 8.4+.

### libmcrypt `config.sub` too old

libmcrypt 2.5.8's `config.sub` (from 2007) doesn't recognize modern Darwin kernel versions. On Apple Silicon it fails on `arm-apple-darwin`; on Intel with macOS 13+ it may fail on `x86_64-apple-darwin22+`. Replace with MacPorts version in both cases:
```bash
cp /opt/local/share/libtool/build-aux/config.sub libmcrypt-2.5.8/config.sub
```
`build-mamp-ext.sh` does this automatically.

### libmcrypt C89 syntax

Old K&R style declarations fail under modern clang. Build with `CFLAGS="-std=gnu89 -Wno-implicit-function-declaration -Wno-implicit-int"`.

### mcrypt PHP extension: `php_rand.h` removed in 8.4

Create a shim:
```bash
echo '#pragma once
#include "ext/standard/php_random.h"' \
  > /Applications/MAMP/bin/php/php8.4.23/include/php/ext/standard/php_rand.h
```
`build-mamp-ext.sh` does this automatically.

### imagick PHP 8.4: `php_strtolower` removed

`build-mamp-ext.sh` patches `imagick.c` before building:
```bash
sed -i.bak 's/php_strtolower(\([^,]*\), \([^)]*\))/zend_str_tolower_copy(\1, \1, \2)/g' imagick.c
```

### libpq build target and linking crashes

PostgreSQL 16 uses `strchrnul` (requires macOS 15.4+) when compiling against modern macOS SDKs. If `MACOSX_DEPLOYMENT_TARGET=12.0` is used, compilation normally fails due to unguarded availability. Additionally, OpenSSL calls `atexit` which PG's shared library checks reject.

To resolve this:
1. We configure PostgreSQL with `CFLAGS="-arch $ARCH -Wno-unguarded-availability-new"`, `--without-icu`, and `--without-zlib`, allowing it to compile cleanly targetting `12.0`.
2. We compile only `libpq.a` and its helper archives (`libpgcommon.a`, `libpgport.a`), installing them manually.
3. PHP extensions normally link against `libpq.a` with `-undefined dynamic_lookup`, which leaves dependencies on OpenSSL, zlib, and PG's helpers unresolved, crashing at runtime. To prevent this, the build script patches the generated extension `Makefile` to explicitly link against `-lpgcommon -lpgport -lssl -lcrypto -lz`.

### igbinary.h path

The root `igbinary.h` uses a relative include for `src/php7/igbinary.h`. Copy `src/php7/igbinary.h` directly as `igbinary.h` into each PHP's include dir so redis/memcached can find it:
```bash
cp src/php7/igbinary.h /Applications/MAMP/bin/php/php8.3.32/include/php/ext/igbinary/igbinary.h
```
`build-mamp-ext.sh` does this automatically after building igbinary.

### `pcre2.h` not found in phpize builds

phpize-based builds don't search `$MAMPLIB/include`. Fix: add `CPPFLAGS="-I$MAMPLIB/include"` to configure invocations. Done automatically in `_build_ext_one`.

### cmake not installed

`build-mamp-ext.sh` auto-downloads cmake 3.29.6 universal binary to `"$BUILD/cmake-bin/"` if `cmake` is not on PATH.

### pear.conf is PHP serialized — string lengths matter

If you manually edit `pear.conf`, update the `s:N:` length prefix for every string you change. Use the Python script in [Step 4](#pear.conf) to regenerate safely.

### MAMP PRO conf dir

`/Library/Application Support/appsolute/MAMP PRO/conf/php<version>.ini` is auto-generated by MAMP PRO at runtime from `php.ini.temp`. Changes are overwritten on next MAMP PRO save. Edit `php.ini.temp` instead (or use the MAMP PRO UI).

`php.ini.temp` uses `MAMP_xxx_MAMP` placeholders for MAMP-UI-managed extensions (apcu, imagick, tidy, etc.). All other extension lines (`extension=foo.so`) are passed through verbatim into the generated ini. Non-standard or opt-in extensions are commented (`; extension=foo.so`) so they don't load by default.

**PHP 8.5 + OPcache:** `php.ini.temp` contains a `MAMP_OPcache_MAMP` placeholder pointing to `opcache.so`. Since OPcache is static in PHP 8.5, no `opcache.so` exists.

> [!WARNING]
> **MAMP PRO GUI Compatibility Limit:** PHP 8.5.x and 8.6.x are **not** supported by the MAMP PRO v6.x GUI/dropdown menu. The legacy app binary contains compiled-in version validations that filter out version numbers `>= 8.5.0` (even when spoofing directories or binaries). However, PHP 8.5.x and 8.6.x remain fully functional for command-line use (CLI) and custom Apache/CGI setups.

---

## PHP 8.5 Gotchas

### OPcache is always static — no opcache.so

`--enable-opcache` was removed as a configure flag in PHP 8.5; OPcache is always compiled into the binary. Comment out the `zend_extension` line in `php.ini`:

```ini
; opcache is statically compiled into PHP 8.5 — no .so needed
```

OPcache still works and all `opcache.*` ini settings apply.

### `php_smart_string.h` moved

`ext/standard/php_smart_string.h` was removed; functionality moved to `Zend/zend_smart_string.h`. Create a compat shim before building extensions (affects igbinary, oauth, redis, yaml, memcached, imagick):

```bash
cat > /Applications/MAMP/bin/php/php8.5.12/include/php/ext/standard/php_smart_string.h << 'EOF'
#pragma once
#include "Zend/zend_smart_string.h"
EOF
```

`build-mamp-ext.sh ext85` does **not** do this automatically — create the shim first.

### `php_random.h` moved

`ext/standard/php_random.h` moved to `ext/random/php_random.h`. The `php_rand.h` shim for mcrypt must point to the new location:

```bash
cat > /Applications/MAMP/bin/php/php8.5.12/include/php/ext/standard/php_rand.h << 'EOF'
#pragma once
#include "ext/random/php_random.h"
EOF
```

`build-mamp-ext.sh` creates this automatically via `build_mcrypt_ext_85`.

### Extension versions

`zend_exception_get_default()` was removed in PHP 8.5; extensions calling it fail to compile.
Current pins used for every PHP 8.2–8.5 build:

| Extension  | Version |
|------------|---------|
| xdebug     | 3.5.3   |
| oauth      | 2.0.10  |
| memcached  | 3.4.0   |

`build-mamp-ext.sh` applies these automatically. xdebug 3.5.x refuses PHP ≥ 8.6, so `ext86`
skips it.

---

## PHP 8.6 Gotchas

### FreeType Header & `HAVE_FT2BUILD_H`

In PHP 8.6, the bundled `libgd` requires `<ft2build.h>` to be included before `<freetype/freetype.h>`. PHP's `gd.c` wraps `<ft2build.h>` inside `#if defined(HAVE_FT2BUILD_H)`. If this macro is undefined during compilation against external FreeType headers, the compiler directly encounters `<freetype/freetype.h>` and errors with:
```
#error "ft2build.h" hasn't been included yet!
```
`build-php-mamp.sh` resolves this automatically by adding `-DHAVE_FT2BUILD_H` to `FREETYPE2_CFLAGS` and appending `#define HAVE_FT2BUILD_H 1` to `main/php_config.h`.

### WebP Linker Libraries (`libwebpdemux` & `libwebpmux`)

PHP 8.6 GD animated WebP and probe routines reference symbols in `libwebpdemux` and `libwebpmux` (e.g. `WebPAnimDecoderNewInternal`, `WebPMuxCreateInternal`). `build-php-mamp.sh` ensures `WEBP_LIBS` includes `-lwebpdemux -lwebpmux` alongside `-lwebp`.

### OPcache is Statically Compiled (No opcache.so)

As in PHP 8.5, OPcache is compiled directly into the PHP 8.6 core binary. No external `opcache.so` is built. The dynamic loading line `zend_extension=.../opcache.so` must remain commented out in `php.ini` (which `configure-mamp-ini.py` handles automatically for `8.6.x`). OPcache functionality is fully active built-in.

### Deprecated Session Settings

`session.sid_length = 26` and `session.sid_bits_per_character = 5` are deprecated in PHP 8.4+ and 8.6. `configure-mamp-ini.py` comments them out in generated `php.ini` and `php.ini.temp` to suppress startup deprecation warnings.

### Pre-release Source Tarball Download Fallback

PHP 8.6 is currently in pre-release/RC stages. `build-php-mamp.sh` includes automatic discovery fallbacks:
1. Standard distribution download (`https://www.php.net/distributions/php-<version>.tar.gz`)
2. PHP QA / Release Candidates API (`https://www.php.net/release-candidates.php?format=json` or `downloads.php.net`)
3. GitHub release archive tag (`https://github.com/php/php-src/archive/refs/tags/php-<version>.tar.gz`)

### PECL Extension Support for PHP 8.6 (`ext86`)

Run extension compilation for PHP 8.6 using:
```bash
bash "$BUILD/build-mamp-ext.sh" ext86
```
PHP 8.6 removed several internal macros and changed session-handler signatures. The script
handles this with `php86-compat.h` (force-included) plus targeted patches:

- **Compat header**: `XtOffsetOf`, `zval_dtor`, `zval_is_true`, `INI_STR/INT/FLT/BOOL`,
  `WRONG_PARAM_COUNT`, `php_hash_bin2hex`.
- `xdebug` 3.5.3: both configure version gates widened and `ZSTR_INIT_LITERAL(tmp_name, …)`
  replaced; loads normally, disabled by default.
- `ssh2` 1.5.0: `zval_is_true`/`zval_dtor` replacements.
- `oauth` 2.0.10: `XtOffsetOf` → `offsetof`.
- `apcu` 5.1.24: `php_verror()` signature.
- `mcrypt` 1.0.9: stream-filter code dropped (no `mcrypt.*` filters on 8.6).
- `redis` 6.3.0: session handlers adapted to `zend_string*`; built without igbinary.
- `igbinary`, `uploadprogress`, `yaml`, `memcached`, `imagick`, `pgsql`, `pdo_pgsql`,
  `tidy`, and the System V IPC extensions all build and load.

`imap` is deliberately **not** built: PHP removed it from core in 8.4, and the PECL package
requires UW `c-client` 2007f — unmaintained since 2007, with known parser CVEs and a
non-standard license.

---

## macOS Specific Build Gotchas

### Missing Apache Build Directory (`/Applications/MAMP/Library/build/`)

MAMP does not include the Apache HTTPD build directory (containing `config_vars.mk` and `instdso.sh`) that `apxs` requires to configure/compile third-party Apache modules (like `libphp.so`). When compiling on a clean machine:
1. Re-create the build directory by downloading the matching Apache source (e.g. Apache 2.4.54 for MAMP 6.9), running `./configure --prefix=/Applications/MAMP/Library` (pointing at MAMP's `apr-1-config` and `apu-1-config`), and copying the output `build/*` to `/Applications/MAMP/Library/build/`.
2. Copy `instdso.sh` from `/usr/share/httpd/build/instdso.sh` into `/Applications/MAMP/Library/build/`.
3. Symlink `/Applications/MAMP/Library/build-1/libtool` to `/Applications/MAMP/Library/bin/libtool`.

### `apxs` SAPI Installation Failure (`httpd.conf` target)

During `make install` for PHP, `apxs` attempts to activate the module in `/Applications/MAMP/Library/conf/httpd.conf`. Since MAMP does not maintain its configuration files at this path, the command will fail:
* **Fix:** Create a dummy file at `/Applications/MAMP/Library/conf/httpd.conf` populated with a placeholder directive preceded by a newline character (e.g. `\nLoadModule foo_module modules/mod_foo.so\n`). `apxs` parses this string regex pattern to locate insertion points; if it is not formatted exactly with a newline before `LoadModule`, the installation process will crash.

### CXXFLAGS & System C++ Standard Library Overrides

Do not specify `-isystem /Library/Developer/CommandLineTools/.../c++/v1` inside `CXXFLAGS`. Overriding standard C++ header lookups with absolute SDK paths disrupts standard C header resolution (like `<stdint.h>`), resulting in compile errors (e.g., `unknown type name int32_t`, `int8_t` or `UBool` definition issues in the `intl` extension). Let clang automatically resolve SDK headers:
* **Fix:** Keep CXXFLAGS simple: `CXXFLAGS="-arch $ARCH"`.

### macOS OS Version Backward Compatibility

Apple's clang stamps each binary with two versions: `minos` (minimum OS the binary will load on) and `sdk` (the SDK it was compiled against). `sdk` is taken from the build host (27.0 on the machine these artifacts were built on) and is not a runtime requirement — `minos` is. If you build without setting a deployment target, `minos` defaults to the host OS, and a binary linking modern system symbols (e.g. `strchrnul`, introduced in macOS 15.4) crashes immediately with `dyld: Symbol not found` on anything older:

* **Fix:** target the oldest OS you intend to support. All build scripts (`build-php-mamp.sh`, `build-mamp-ext.sh`, `compile-all-php.sh`, `build-zlib-mamp.sh`, `build-deps-mamp.sh`) already default to `12.0`, and read the variable when set:
  ```bash
  export MACOSX_DEPLOYMENT_TARGET="12.0"   # Monterey — the default in these scripts
  ```
  Raise it (e.g. `13.0` for Ventura, `15.0` for Sequoia) only when you deliberately want a higher floor.

* **Verify:** `minos` on the shipped `php`, `php-cgi` and every `.so` should read `12.0` — see [Verification](#verification). Dependencies built as side effects (notably `libpq`) must use the same target, otherwise the extension links against symbols the floor does not provide; see [libpq build target and linking crashes](#libpq-build-target-and-linking-crashes).
