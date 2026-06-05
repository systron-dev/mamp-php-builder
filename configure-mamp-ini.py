import os
import re

versions = {
    "8.2.31": "no-debug-non-zts-20220829",
    "8.3.31": "no-debug-non-zts-20230831",
    "8.4.21": "no-debug-non-zts-20240924",
    "8.5.6":  "no-debug-non-zts-20250925",
}

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

for version, ext_hash in versions.items():
    print(f"Configuring PHP {version}...")
    target_dir = f"/Applications/MAMP/bin/php/php{version}/conf"
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

    new_ext_block_ini = """;extension=apcu.so
;extension=igbinary.so
;extension=imagick.so
;extension=memcached.so
;extension=oauth.so
;extension=redis.so
;extension=tidy.so

;extension=imap.so
extension=pgsql.so
extension=pdo_pgsql.so

;extension=mcrypt.so
;extension=ssh2.so
;extension=yaml.so
;extension=uploadprogress.so
;extension=sysvsem.so
;extension=sysvshm.so
;extension=sysvmsg.so
;extension=shmop.so"""

    # For PHP 8.5.6 opcache is static, so we comment out its loading in php.ini
    if version == "8.5.6":
        new_php_ini = new_php_ini.replace(
            f'zend_extension="/Applications/MAMP/bin/php/php8.5.6/lib/php/extensions/no-debug-non-zts-20250925/opcache.so"',
            f';zend_extension="/Applications/MAMP/bin/php/php8.5.6/lib/php/extensions/no-debug-non-zts-20250925/opcache.so"'
        )
        new_php_ini = new_php_ini.replace(
            f'zend_extension="/Applications/MAMP/bin/php/php8.5.6/lib/php/extensions/no-debug-non-zts-20250925/opcache.so"',
            f';zend_extension="/Applications/MAMP/bin/php/php8.5.6/lib/php/extensions/no-debug-non-zts-20250925/opcache.so"'
        )

    if old_ext_block_ini in new_php_ini:
        new_php_ini = new_php_ini.replace(old_ext_block_ini, new_ext_block_ini)
    else:
        print(f"Warning: Old extension block not found in php.ini for {version}!")
        
    if version in ("8.4.21", "8.5.6"):
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

    new_ext_block_temp = """MAMP_apc_MAMPextension=apcu.so
MAMP_Igbinary_MAMPextension=igbinary.so
MAMP_Imagick_MAMPextension=imagick.so
MAMP_Memcached_MAMPextension=memcached.so
MAMP_Oauth_MAMPextension=oauth.so
MAMP_Redis_MAMPextension=redis.so
MAMP_Tidy_MAMPextension=tidy.so

;extension=imap.so
extension=pgsql.so
extension=pdo_pgsql.so

;extension=mcrypt.so
;extension=ssh2.so
;extension=yaml.so
;extension=uploadprogress.so
;extension=sysvsem.so
;extension=sysvshm.so
;extension=sysvmsg.so
;extension=shmop.so"""

    if version == "8.5.6":
        new_php_ini_temp = new_php_ini_temp.replace(
            f'MAMP_OPcache_MAMPzend_extension="/Applications/MAMP/bin/php/php8.5.6/lib/php/extensions/no-debug-non-zts-20250925/opcache.so"',
            f';zend_extension="/Applications/MAMP/bin/php/php8.5.6/lib/php/extensions/no-debug-non-zts-20250925/opcache.so"'
        )

    if old_ext_block_temp in new_php_ini_temp:
        new_php_ini_temp = new_php_ini_temp.replace(old_ext_block_temp, new_ext_block_temp)
    else:
        print(f"Warning: Old extension block not found in php.ini.temp for {version}!")

    if version in ("8.4.21", "8.5.6"):
        new_php_ini_temp = new_php_ini_temp.replace("session.sid_length = 26", ";session.sid_length = 26")
        new_php_ini_temp = new_php_ini_temp.replace("session.sid_bits_per_character = 5", ";session.sid_bits_per_character = 5")

    with open(os.path.join(target_dir, "php.ini.temp"), "w") as f:
        f.write(new_php_ini_temp)

print("Configuration generation complete!")
