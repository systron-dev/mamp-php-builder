---
name: mamp-php-build
description: "PHP 8.2.31, 8.3.31, 8.4.21, 8.5.6 built from source for MAMP v6.9 on Apple Silicon — status, constraints, and lessons learned"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3aba1562-b5c3-44a5-b50e-3e6e54ef7924
---

PHP 8.2.31, 8.3.31, 8.4.21, and 8.5.6 successfully built from source and installed into `/Applications/MAMP/bin/php/` for MAMP v6.9 on Apple Silicon (arm64).

**Why:** MAMP PRO v6.9 no longer offers newer PHP packages for download; only v7.x gets updates. Homebrew packages were rejected — all deps must be self-contained in `/Applications/MAMP/Library`.

**How to apply:** Any future PHP builds for MAMP follow the same process. Use `/tmp/php-build/build-php-mamp.sh <version>` (configure only) + manual make with hidden OpenSSL symlinks.

## Key Files
- `/tmp/php-build/build-php-mamp.sh` — configure script (configure only, not make)
- `/tmp/php-build/build-curl-mamp.sh` — rebuilt libcurl 8.7.1 against OpenSSL 3.3.2 static
- `/tmp/php-build/build-mamp-ext.sh` — extension build script (all PECL extensions + deps)
- `/Applications/MAMP/Library/build/config_vars.mk` — created (MAMP ships without it, apxs needs it)
- `/Applications/MAMP/Library/build/instdso.sh` — copied from `/usr/share/httpd/build/`
- `/Applications/MAMP/Library/build-1/libtool` — symlink to `../bin/libtool` (required by apr-1-config)

## Prerequisites Built Into MAMP Library
- **OpenSSL 3.3.2** static (`no-shared`): `libssl.a` + `libcrypto.a` in `/Applications/MAMP/Library/lib/`
- **libcurl 8.7.1** with OpenSSL 3.3.2 statically embedded (replaced old curl 7.68.0 which used OpenSSL 1.0.2u)

## Critical Build Tricks

1. **Hide `libssl.dylib` and `libcrypto.dylib` symlinks during `make`** — these symlinks point to old OpenSSL 1.0.0; must be hidden so linker uses `.a` files (OpenSSL 3).
   ```bash
   mv $MAMP/lib/libssl.dylib $MAMP/lib/libssl.dylib.hidden
   mv $MAMP/lib/libcrypto.dylib $MAMP/lib/libcrypto.dylib.hidden
   make -j$(sysctl -n hw.ncpu)
   mv $MAMP/lib/libssl.dylib.hidden $MAMP/lib/libssl.dylib
   mv $MAMP/lib/libcrypto.dylib.hidden $MAMP/lib/libcrypto.dylib
   ```

2. **`OPENSSL_LIBS` must use `-L/-l` flags** — `PHP_EVAL_LIBLINE` silently ignores full `.a` paths; use `-L$MAMP/lib -lssl -lcrypto` not `$MAMP/lib/libssl.a $MAMP/lib/libcrypto.a`.

3. **Add `-licuio` to EXTRA_LIBS** — MAMP has ICU 56 with versioned symbols (`u_sprintf_56` in `libicuio`). PHP 8.3 needs explicit `-licuio`; PHP 8.4 adds it automatically.
   ```bash
   python3 -c "import re; f='/tmp/php-build/php-8.3.31/Makefile'; c=open(f).read(); open(f,'w').write(re.sub(r'^(EXTRA_LIBS = .+)$', r'\1 -licuio', c, flags=re.MULTILINE))"
   ```

4. **PHP 8.4 removed flags**: `--with-zlib-dir` and `--with-kerberos` — build script handles this with `$ZLIB_DIR_FLAG` and `$KERBEROS_FLAG` conditionals.

5. **Trap handler bug**: `[ $VAR -eq 1 ] && cmd` returns exit code 1 when VAR=0 (test fails); add `|| true` to prevent script exit code pollution.

## Post-Install Per Version

### 1. libphp.so
Copy `modules/libphp.so` from `/Applications/MAMP/Library/modules/libphp.so` after `make install`.

### 2. conf/php.ini
Copy from nearest existing version. Fix `extension_dir` and `zend_extension` paths. Disable `extension=imap.so`, `extension=pgsql.so`, `extension=pdo_pgsql.so` (no C libs).

### 3. conf/pear.conf (MISSING from fresh build — must create manually)
PHP-serialized format — string lengths must be recalculated when version string length changes.
Use this Python script (substitute `OLD_VER`, `NEW_VER`, and optionally API hash):

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

# Copy from closest existing version (same major.minor preferred):
with open('/Applications/MAMP/bin/php/php8.3.0/conf/pear.conf') as f:
    base = f.read()

# For same API hash (same minor):
result = update_pear_conf(base, 'php8.3.0', 'php8.3.31')

# For different API hash (new major/minor):
# result = update_pear_conf(base, 'php8.3.0', 'php8.4.21',
#     'no-debug-non-zts-20230831', 'no-debug-non-zts-20240924')

with open('/Applications/MAMP/bin/php/php8.3.31/conf/pear.conf', 'w') as f:
    f.write(result)
```

API hashes by PHP version:
- PHP 8.2.x: `no-debug-non-zts-20220829`
- PHP 8.3.x: `no-debug-non-zts-20230831`
- PHP 8.4.x: `no-debug-non-zts-20240924`
- PHP 8.5.x: `no-debug-non-zts-20250925`

### 4. conf/php.ini.temp (MISSING from fresh build — must create manually)
MAMP PRO template file (contains `MAMP_xxx_MAMP` placeholders, not live values).
Base on closest existing version's `php.ini.temp`, substitute version and API hash:

```python
with open('/Applications/MAMP/bin/php/php8.3.0/conf/php.ini.temp') as f:
    base = f.read()

# Same API hash:
result = base.replace('php8.3.0', 'php8.3.31')

# Different API hash:
# result = base.replace('php8.3.0', 'php8.4.21') \
#              .replace('no-debug-non-zts-20230831', 'no-debug-non-zts-20240924')

with open('/Applications/MAMP/bin/php/php8.3.31/conf/php.ini.temp', 'w') as f:
    f.write(result)
```

Last line of php.ini.temp must be:
`; DONT REMOVE: MAMP PRO php<version>.ini template compatibility version: 16`

### 5. MAMP PRO conf dir
`/Library/Application Support/appsolute/MAMP PRO/conf/` — MAMP PRO auto-generates `php<version>.ini` here at runtime from `php.ini.temp`. No manual action needed; will be created when MAMP PRO first activates the PHP version.

## What's NOT included vs stock MAMP PHP
- imap (no libc-client — deliberately skipped)
- xmlrpc (removed from PHP 8.3+ core, PECL only)

## Distribution (2026-06-04)

Files in `/Users/ogeorgi/Downloads/mamp-updated-php/`:
- `php8.2.31-arm64.tar.gz` — full PHP install (untar into `/Applications/MAMP/bin/php/`)
- `php8.3.31-arm64.tar.gz`
- `php8.4.21-arm64.tar.gz`
- `php8.5.6-arm64.tar.gz`
- `build-php-mamp.sh` — configure script (synced from `/tmp/php-build/`)
- `build-curl-mamp.sh` — libcurl rebuild script
- `build-mamp-ext.sh` — extension build script (synced from `/tmp/php-build/`)
- `BUILD.md` — full build guide
- `README.md` — quick reference

Tarballs contain `phpX.Y.Z/` rooted paths (conf/, bin/, lib/, include/, php/). Packed from `/Applications/MAMP/bin/php/` with `--exclude='*.DS_Store'`. Tarballs are repacked whenever config or extensions change.

## Extension Gap Analysis vs PHP 7.4.33 (done 2026-06-04)

Compared `/Applications/MAMP/bin/php/php7.4.33/lib/php/extensions/no-debug-non-zts-20190902/` against new builds.

### Missing from new builds — built and added
All 4 are POSIX IPC extensions (no external C deps, no OpenSSL needed):
- `sysvsem.so` — System V semaphores
- `sysvshm.so` — System V shared memory  
- `sysvmsg.so` — System V message queues
- `shmop.so` — shared memory operations

Built via phpize from PHP source trees (`/tmp/php-build/php-X.Y.Z/ext/<name>/`). Added `build_sysv_ext()` to `build-mamp-ext.sh`; run with `bash build-mamp-ext.sh sysv`. All 4 enabled in `php.ini` for 8.3.31, 8.4.21, 8.5.6.

### Config files updated (all 3 versions: 8.3.31, 8.4.21, 8.5.6)

Three config layers per version, all kept in sync:
1. `conf/php.ini` — standalone runtime (CLI / direct Apache)
2. `conf/php.ini.temp` — MAMP PRO template (source for generated live conf)
3. `/Library/Application Support/appsolute/MAMP PRO/conf/phpX.Y.Z.ini` — MAMP PRO live conf (not present for 8.5.6 until first MAMP PRO activation)

Extension policy, based on MAMP reference defaults (8.2.13, 8.3.0):
- **Enabled (hardcoded)**: `pgsql.so`, `pdo_pgsql.so`
- **Enabled (MAMP UI managed via `MAMP_xxx_MAMP` placeholders in template)**: apcu, igbinary, imagick, memcached, oauth, redis, tidy, opcache, xdebug
- **Commented (available, opt-in)**: mcrypt, ssh2, uploadprogress, yaml, sysvsem, sysvshm, sysvmsg, shmop
- **Commented (unavailable)**: imap — no libc-client built; removed from PHP 8.4+

php.ini.temp `MAMP_OPcache_MAMP` placeholder in 8.5.6 points to non-existent `opcache.so` (static in 8.5). After MAMP PRO first activates 8.5.6 and generates `php8.5.6.ini`, manually comment out that `zend_extension` line.

### Deliberately skipped
- `apc.so` — dead; APCu replaces it
- `memcache.so` — old client; memcached replaces it
- `imap.so` — deprecated 8.3, removed 8.4; no libc-client built
- `xmlrpc.so` — PECL only in 8.x; obsolete (REST replaced XML-RPC)
- `yaz.so` — Z39.50 library protocol; libyaz C build failed (libxml2/libxslt deps); extremely niche

### Already static in new builds (not missing)
- `gettext` — compiled in via `--with-gettext=$MAMP`

---

## PHP 8.2.31 Build Notes (2026-06-04)

PHP 8.2.31 built and installed to `/Applications/MAMP/bin/php/php8.2.31/`.

### PHP 8.2-specific vs 8.3

1. **`-licuio` automatic** — unlike 8.3, no Makefile patch needed. PHP 8.2's configure picks up `-licuio` directly from `ICU_LIBS` env var into `EXTRA_LIBS`. Verify with `grep licuio /tmp/php-build/php-8.2.31/Makefile`.

2. **`--with-zlib-dir` and `--with-kerberos` still valid** — not removed until 8.4. `build-php-mamp.sh` handles this via `$ZLIB_DIR_FLAG` / `$KERBEROS_FLAG` conditionals (set for non-8.4/8.5/8.6).

3. **`--with-xmlrpc` still in core** — xmlrpc was in PHP 8.2 core (removed in 8.3). Not used — we skip it (XMLRPC_FLAG stays empty in build script).

4. **API hash: `no-debug-non-zts-20220829`** — same as all 8.2.x. pear.conf and php.ini.temp sourced from `php8.2.13/conf/` with version string `php8.2.13` → `php8.2.31` substitution only (no API hash change needed).

5. **imap disabled** — 8.2.13 (MAMP reference) had `extension=imap.so` enabled; we comment it out since no libc-client is built.

6. **Extension versions** — same as 8.3.31 (no version bumps needed; 8.5-specific versions not required).

7. **No special shims** — `php_smart_string.h` and `php_rand.h` shims are only needed for 8.5 and 8.4 respectively. 8.2 builds cleanly with no patches.

### Post-install for 8.2.31
- `libphp.so`: copied from `/Applications/MAMP/Library/modules/libphp.so`
- `php.ini`: from 8.2.13, `sed 's/php8.2.13/php8.2.31/g'`
- `pear.conf`: Python update_pear_conf script, base=8.2.13, no hash change
- `php.ini.temp`: base=8.2.13, `.replace('php8.2.13', 'php8.2.31')`

---

## PHP 8.5.x Build Notes (2026-06-04)

PHP 8.5.6 built and installed to `/Applications/MAMP/bin/php/php8.5.6/`.

> [!IMPORTANT]
> **MAMP PRO GUI Compatibility Limit:** PHP 8.5.x is **not** supported by the MAMP PRO v6.x GUI/dropdown list. This is due to hardcoded/compiled-in version checks inside the MAMP PRO app binary that filter out version numbers `>= 8.5.0`. It cannot be spoofed using symlinks or binary patching due to internal app constraints, but it remains fully usable directly via the CLI (`/Applications/MAMP/bin/php/php8.5.6/bin/php`) or via manual Apache/CGI configurations.

### PHP 8.5-specific changes vs 8.4

1. **OPcache static** — `--enable-opcache` removed as configure option; OPcache always compiled in statically. No `opcache.so` file. Comment out the `zend_extension=.../opcache.so` line in php.ini. OPcache settings (opcache.enable etc.) still apply via ini.

2. **`php_smart_string.h` removed from `ext/standard/`** — moved to `Zend/zend_smart_string.h`. Create compat shim:
   ```bash
   cat > $PHP85/include/php/ext/standard/php_smart_string.h << 'EOF'
   #pragma once
   #include "Zend/zend_smart_string.h"
   EOF
   ```
   Fixes: igbinary, oauth, redis, yaml, memcached, imagick.

3. **`php_random.h` moved** — `ext/standard/php_random.h` → `ext/random/php_random.h`. Fix compat shim in php_rand.h:
   ```bash
   cat > $PHP85/include/php/ext/standard/php_rand.h << 'EOF'
   #pragma once
   #include "ext/random/php_random.h"
   EOF
   ```
   Fixes: mcrypt.

4. **Extension version bumps required for PHP 8.5** (`zend_exception_get_default` removed → use `zend_ce_exception` directly):
   - xdebug: 3.4.3 → **3.5.1** (3.4.x rejects PHP ≥ 8.5 at configure time)
   - oauth: 2.0.9 → **2.0.10**
   - memcached: 3.3.0 → **3.4.0**

5. **New PHP 8.5 builtins** — `lexbor` (HTML5 parser) and `uri` (URL handling) are now built-in static extensions.

### build-mamp-ext.sh ext85 target

Use `bash /tmp/php-build/build-mamp-ext.sh ext85` to build all extensions for PHP 8.5 only. Requires compat shims above to be in place first.

---

## Extension Build Session (2026-06-04)

Script: `/tmp/php-build/build-mamp-ext.sh`
C deps installed to: `/tmp/php-build/ext-deps/`
Extension dirs:
- PHP 8.3.31: `/Applications/MAMP/bin/php/php8.3.31/lib/php/extensions/no-debug-non-zts-20230831/`
- PHP 8.4.21: `/Applications/MAMP/bin/php/php8.4.21/lib/php/extensions/no-debug-non-zts-20240924/`
- PHP 8.5.6: `/Applications/MAMP/bin/php/php8.5.6/lib/php/extensions/no-debug-non-zts-20250925/`

### Extensions built successfully (as of session end)

| Extension | 8.3.31 | 8.4.21 | 8.5.6  | Notes |
|-----------|--------|--------|--------|-------|
| apcu      | ✓      | ✓      | ✓      | |
| igbinary  | ✓      | ✓      | ✓      | needs smart_string shim |
| imagick   | ✓      | ✓      | ✓      | needs smart_string shim |
| mcrypt    | ✓      | ✓      | ✓      | needs php_rand shim |
| memcached | ✓      | ✓      | ✓ 3.4.0 | use 3.4.0 for PHP 8.5 |
| oauth     | ✓      | ✓      | ✓ 2.0.10 | use 2.0.10 for PHP 8.5 |
| redis     | ✓      | ✓      | ✓      | needs smart_string shim |
| ssh2      | ✓      | ✓      | ✓      | |
| uploadprogress | ✓ | ✓    | ✓      | |
| xdebug    | ✓      | ✓      | ✓ 3.5.1 | use 3.5.1 for PHP 8.5 |
| yaml      | ✓      | ✓      | ✓      | needs smart_string shim |
| opcache   | ✓ (pre-existing) | ✓ | static (built-in) | no .so in PHP 8.5 |
| pgsql     | ✓      | ✓      | ✓      | |
| pdo_pgsql | ✓      | ✓      | ✓      | |
| tidy      | ✓      | ✓      | ✓      | |
| opcache   | ✓ (pre-existing) | ✓ |
| tidy      | ✓ (pre-existing) | ✓ |

### Still pending (background job running at session end)
- **mcrypt PHP 8.4**: `php_rand.h` removed in 8.4 — script adds compat shim `#include "ext/standard/php_random.h"`
- **memcached**: needs `--with-zlib-dir=$MAMPLIB` (added in script)
- **pgsql + pdo_pgsql**: needs `LIBS="-lpq -lssl -lcrypto -lz"` for configure link test (added in script)
- **yaz**: libyaz C lib failed (libxml2/libxslt dep issues); low priority

### Key bugs found and fixed in build-mamp-ext.sh

1. **`if "$@"` disables set -e** — `try_build` used `if func` which prevents set -e from propagating; fixed by adding `|| return 1` to each critical step in `_build_ext_one`

2. **pcre2.h missing** — phpize builds don't search `$MAMPLIB/include`; fixed by adding `CPPFLAGS="-I$MAMPLIB/include"` in `_build_ext_one`

3. **igbinary.h wrong path** — root `igbinary.h` includes `src/php7/igbinary.h` relatively; fixed to copy `src/php7/igbinary.h` directly as `igbinary.h`

4. **libmcrypt config.sub too old** — doesn't recognize arm-apple-darwin25; fixed by copying `/opt/local/share/libtool/build-aux/config.sub`

5. **libmcrypt C89 code** — old K&R style declarations; fixed with `CFLAGS="-std=gnu89 -Wno-implicit-function-declaration -Wno-implicit-int"`

6. **libpq MACOSX_DEPLOYMENT_TARGET=12.0** — `strchrnul` requires macOS 15.4+; fixed by unsetting deployment target for PG build

7. **libpq dylib atexit check** — OpenSSL calls atexit, PG rejects this in dylib; fixed by building only `libpq.a` and doing manual install

8. **imagick PHP 8.4** — `php_strtolower` removed; script patches `imagick.c` before build

9. **memcached zlib** — `--with-zlib-dir=$MAMPLIB` missing; fixed in script

10. **cmake missing** — script auto-downloads cmake 3.29.6 universal binary from cmake.org to `/tmp/php-build/cmake-bin/`

11. **imagick segfault on phpinfo() / php --info** — ImageMagick detected optional dynamic delegates from the host system (like Graphviz/`gvc` or `libraw`) which are not packed into MAMP. The linker resolved them using dynamic lookup, resulting in symbol references to `NULL` (like `libraw_version` in `RegisterDNGImage` or `gvContext` in `RegisterDOTImage`) which segfaulted when printing module info. Fixed by passing explicit `--without-` flags for all optional delegates (`--without-gvc`, `--without-raw`, `--without-fontconfig`, `--without-pango`, etc.) during ImageMagick configuration, producing a minimal static library.

12. **Build folder permissions** — Multi-user shared machines caused permission conflicts inside `/tmp/php-build/` (e.g. running scripts under different accounts). Fixed by updating the scripts to use `/tmp/php-build-${USER}` dynamically.

### C libraries built (in /tmp/php-build/ext-deps/)
- libyaml 0.2.5 ✓
- libssh2 1.11.1 ✓ (against MAMP OpenSSL 3 static)
- libmcrypt 2.5.8 ✓
- libmemcached-awesome 1.1.4 ✓
- libpq (PostgreSQL 16.3 client only) ✓
- libjpeg-turbo 3.0.3 ✓
- libpng 1.6.43 ✓
- libtiff 4.6.0 ✓
- libwebp 1.4.0 ✓
- freetype 2.13.2 ✓
- ImageMagick 7.1.1-33 ✓
- libyaz 5.34.0 ✗ (libxml2/libxslt dep issues — skip)

### Next session: re-run pending extensions
```bash
cd /tmp/php-build
bash build-mamp-ext.sh mcrypt
bash build-mamp-ext.sh memcached
bash build-mamp-ext.sh pgsql
```
Then check: `ls /Applications/MAMP/bin/php/php8.3.31/lib/php/extensions/no-debug-non-zts-20230831/`
