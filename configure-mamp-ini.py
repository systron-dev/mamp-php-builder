import os
import re

versions = {
    "8.2.31": "no-debug-non-zts-20220829",
    "8.3.31": "no-debug-non-zts-20230831",
    "8.4.21": "no-debug-non-zts-20240924",
    "8.5.6":  "no-debug-non-zts-20250925",
    "8.2.32": "no-debug-non-zts-20220829",
    "8.3.32": "no-debug-non-zts-20230831",
    "8.4.23": "no-debug-non-zts-20240924",
    "8.5.8":  "no-debug-non-zts-20250925",
    "8.2.33": "no-debug-non-zts-20220829",
    "8.3.33": "no-debug-non-zts-20230831",
    "8.4.24": "no-debug-non-zts-20240924",
    "8.5.9":  "no-debug-non-zts-20250925",
    "8.2.34": "no-debug-non-zts-20220829",
    "8.3.35": "no-debug-non-zts-20230831",
    "8.4.26": "no-debug-non-zts-20240924",
    "8.5.11": "no-debug-non-zts-20250925",
    "8.6.0RC3": "no-debug-non-zts-20260924",
    "8.2.35": "no-debug-non-zts-20220829",
    "8.3.36": "no-debug-non-zts-20230831",
    "8.4.27": "no-debug-non-zts-20240924",
    "8.5.12": "no-debug-non-zts-20250925",
    "8.6.0RC4": "no-debug-non-zts-20260924",
}

# MAMP Pro only lists version dirs whose name is numeric-only (phpX.Y.Z), so RC
# and beta builds are installed under the stripped numeric name.
versions = {re.sub(r"^(\d+\.\d+\.\d+).*", r"\1", k): v for k, v in versions.items()}

base_dir = "/Applications/MAMP/bin/php/php8.2.0/conf"

# Read base files
with open(os.path.join(base_dir, "pear.conf"), "r") as f:
    base_pear_conf = f.read()

with open(os.path.join(base_dir, "php.ini"), "r") as f:
    base_php_ini = f.read()

with open(os.path.join(base_dir, "php.ini.temp"), "r") as f:
    base_php_ini_temp = f.read()

def update_pear_conf(content, old_ver, new_ver, old_hash, new_hash):
    def replace_serialized_str(m):
        s = m.group(1)
        new_s = s.replace(old_ver, new_ver).replace(old_hash, new_hash)
        if new_s != s:
            return f's:{len(new_s)}:"{new_s}"'
        return m.group(0)
    return re.sub(r's:\d+:"([^"]*)"', replace_serialized_str, content)

# Extensions shipped as shared modules. Order matters: igbinary must load before
# redis/memcached. pgsql/pdo_pgsql are only available once build-mamp-ext.sh ran.
SHARED_EXTS = [
    "apcu", "igbinary", "imagick", "memcached", "oauth", "redis", "tidy",
    "imap", "pgsql", "pdo_pgsql", "mcrypt", "ssh2", "yaml", "uploadprogress",
    "sysvsem", "sysvshm", "sysvmsg", "shmop",
]
# php.ini.temp uses MAMP_*_MAMP markers so MAMP PRO can toggle these in its GUI.
MAMP_MARKERS = {
    "apcu": "MAMP_apc_MAMP",
    "igbinary": "MAMP_Igbinary_MAMP",
    "imagick": "MAMP_Imagick_MAMP",
    "memcached": "MAMP_Memcached_MAMP",
    "oauth": "MAMP_Oauth_MAMP",
    "redis": "MAMP_Redis_MAMP",
    "tidy": "MAMP_Tidy_MAMP",
}

def ext_available(version, ext_hash, name):
    path = f"/Applications/MAMP/bin/php/php{version}/lib/php/extensions/{ext_hash}/{name}.so"
    return os.path.exists(path)

def build_ini_ext_block(version, ext_hash):
    """Enable every shared extension actually present; comment out absent ones."""
    lines = []
    for name in SHARED_EXTS:
        prefix = "" if ext_available(version, ext_hash, name) else ";"
        lines.append(f"{prefix}extension={name}.so")
    if ext_available(version, ext_hash, "xdebug"):
        lines.append(f';zend_extension="/Applications/MAMP/bin/php/php{version}/lib/php/extensions/{ext_hash}/xdebug.so"')
    return "\n".join(lines)

def build_temp_ext_block(version, ext_hash):
    lines = []
    for name in SHARED_EXTS:
        prefix = "" if ext_available(version, ext_hash, name) else ";"
        marker = MAMP_MARKERS.get(name, "")
        lines.append(f"{prefix}{marker}extension={name}.so")
    if ext_available(version, ext_hash, "xdebug"):
        lines.append(f';zend_extension="/Applications/MAMP/bin/php/php{version}/lib/php/extensions/{ext_hash}/xdebug.so"')
    return "\n".join(lines)

for version, ext_hash in versions.items():
    php_dir = f"/Applications/MAMP/bin/php/php{version}"
    if not os.path.isdir(php_dir):
        print(f"Skipping PHP {version} (not installed)")
        continue
    print(f"Configuring PHP {version}...")
    target_dir = f"{php_dir}/conf"
    os.makedirs(target_dir, exist_ok=True)
    
    # 1. Generate pear.conf
    new_pear_conf = update_pear_conf(
        base_pear_conf,
        "php8.2.0",
        f"php{version}",
        "no-debug-non-zts-20220829",
        ext_hash
    )
    new_pear_conf = new_pear_conf.replace("php8.2.0", f"php{version}")
    
    with open(os.path.join(target_dir, "pear.conf"), "w") as f:
        f.write(new_pear_conf)
        
    # 2. Generate php.ini
    new_php_ini = base_php_ini.replace("php8.2.0", f"php{version}").replace("no-debug-non-zts-20220829", ext_hash)
    
    old_ext_block_ini = """;extension=apcu.so

extension=imap.so
extension=pgsql.so
extension=pdo_pgsql.so

;extension=imagick.so
;extension=tidy.so
;extension=oauth.so
;extension=yaml.so
;extension=uploadprogress.so"""

    new_ext_block_ini = build_ini_ext_block(version, ext_hash)

    # For PHP 8.5.x and 8.6.x opcache is static, so we comment out its loading in php.ini
    if version.startswith("8.5.") or version.startswith("8.6."):
        new_php_ini = new_php_ini.replace(
            f'zend_extension="/Applications/MAMP/bin/php/php{version}/lib/php/extensions/{ext_hash}/opcache.so"',
            f';zend_extension="/Applications/MAMP/bin/php/php{version}/lib/php/extensions/{ext_hash}/opcache.so"'
        )

    if old_ext_block_ini in new_php_ini:
        new_php_ini = new_php_ini.replace(old_ext_block_ini, new_ext_block_ini)
    else:
        print(f"Warning: Old extension block not found in php.ini for {version}!")
        
    if version.startswith("8.4.") or version.startswith("8.5.") or version.startswith("8.6."):
        new_php_ini = new_php_ini.replace("session.sid_length = 26", ";session.sid_length = 26")
        new_php_ini = new_php_ini.replace("session.sid_bits_per_character = 5", ";session.sid_bits_per_character = 5")

    with open(os.path.join(target_dir, "php.ini"), "w") as f:
        f.write(new_php_ini)
        
    # 3. Generate php.ini.temp
    new_php_ini_temp = base_php_ini_temp.replace("php8.2.0", f"php{version}").replace("no-debug-non-zts-20220829", ext_hash)
    
    old_ext_block_temp = """MAMP_apc_MAMPextension=apcu.so

extension=imap.so
extension=pgsql.so
extension=pdo_pgsql.so

MAMP_Imagick_MAMPextension=imagick.so
MAMP_Tidy_MAMPextension=tidy.so
MAMP_Oauth_MAMPextension=oauth.so
MAMP_Igbinary_MAMPextension=igbinary.so
MAMP_Memcached_MAMPextension=memcached.so
MAMP_Redis_MAMPextension=redis.so
;extension=uploadprogress.so
;extension=yaml.so"""

    new_ext_block_temp = build_temp_ext_block(version, ext_hash)

    if version.startswith("8.5.") or version.startswith("8.6."):
        new_php_ini_temp = new_php_ini_temp.replace(
            f'MAMP_OPcache_MAMPzend_extension="/Applications/MAMP/bin/php/php{version}/lib/php/extensions/{ext_hash}/opcache.so"',
            f';zend_extension="/Applications/MAMP/bin/php/php{version}/lib/php/extensions/{ext_hash}/opcache.so"'
        )

    if old_ext_block_temp in new_php_ini_temp:
        new_php_ini_temp = new_php_ini_temp.replace(old_ext_block_temp, new_ext_block_temp)
    else:
        print(f"Warning: Old extension block not found in php.ini.temp for {version}!")

    if version.startswith("8.4.") or version.startswith("8.5.") or version.startswith("8.6."):
        new_php_ini_temp = new_php_ini_temp.replace("session.sid_length = 26", ";session.sid_length = 26")
        new_php_ini_temp = new_php_ini_temp.replace("session.sid_bits_per_character = 5", ";session.sid_bits_per_character = 5")

    with open(os.path.join(target_dir, "php.ini.temp"), "w") as f:
        f.write(new_php_ini_temp)

print("Configuration generation complete!")
