#!/usr/bin/env bash
# Rendered into the self-contained installer and sent to a NEW guest over agent stdin.
# Configuration variables are validated on the host. Never enable shell tracing.
set +x
set -Eeuo pipefail
umask 077

guest_setup() {
    [[ $EUID == 0 ]] || exit 1
    [[ ! -e /var/lib/nextcloud-installer ]] || { printf 'Guest already initialized; automatic reruns are refused.\n' >&2; exit 1; }
    mkdir -m 700 /var/lib/nextcloud-installer
    touch /var/log/nextcloud-installer.log
    chmod 600 /var/log/nextcloud-installer.log
    exec >> /var/log/nextcloud-installer.log 2>&1
    STAGE=prerequisites
    trap 'printf "Failed during %s. Review the protected log and README.\n" "$STAGE"; printf "failed: %s\n" "$STAGE" > /var/lib/nextcloud-installer/status; systemctl stop apache2 nextcloud-cron.timer 2>/dev/null || true' ERR
    # Refuse any existing application. This is a fresh-VM installer, not an upgrade tool.
    [[ ! -e /var/www/nextcloud && ! -L /var/www/nextcloud ]]
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ $ID == ubuntu && $VERSION_ID == 24.04 ]]
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y apache2 mariadb-server redis-server nfs-common curl ca-certificates bzip2 \
        php8.3 libapache2-mod-php8.3 php8.3-cli php8.3-mysql php8.3-curl php8.3-gd php8.3-xml \
        php8.3-zip php8.3-mbstring php8.3-intl php8.3-bcmath php8.3-gmp php8.3-apcu php8.3-redis php8.3-imagick
    systemctl stop apache2
    timedatectl set-timezone "$TIMEZONE"

    STAGE=nfs-mount
    [[ ! -e $NFS_MOUNT && ! -L $NFS_MOUNT ]]
    mkdir -p "$NFS_MOUNT"
    local source
    if [[ $NFS_SERVER == *:* ]]; then source="[$NFS_SERVER]:$NFS_EXPORT"; else source="$NFS_SERVER:$NFS_EXPORT"; fi
    printf '%s %s nfs vers=%s,hard,_netdev,nosuid,nodev,noexec,x-systemd.mount-timeout=60s 0 0\n' \
        "$source" "$NFS_MOUNT" "$NFS_VERSION" >> /etc/fstab
    systemctl daemon-reload
    if ! timeout 90 mount "$NFS_MOUNT"; then
        printf 'NFS mount failed. Check export namespace, protocol version, guest IP allowlist, routing and firewall.\n'
        return 1
    fi
    mountpoint -q "$NFS_MOUNT"
    STAGE=nfs-permissions
    # Check as the actual client identity: root squash can deny guest root access.
    # Resolving symlinks also ensures data cannot escape onto the system disk.
    if [[ $(runuser -u www-data -- realpath -e "$DATA_DIR") != "$DATA_DIR" ]] ||
        ! runuser -u www-data -- test -d "$DATA_DIR"; then
        printf 'Dedicated data directory is missing, inaccessible or resolves through a symlink. The storage administrator must create it inside the export and permit www-data traversal.\n'
        return 1
    fi
    if [[ $(runuser -u www-data -- stat -c %u "$DATA_DIR") != "$(id -u www-data)" ]] ||
        [[ ! $(runuser -u www-data -- stat -c %a "$DATA_DIR") =~ ^(700|750)$ ]] ||
        ! runuser -u www-data -- test -r "$DATA_DIR" ||
        ! runuser -u www-data -- test -w "$DATA_DIR" ||
        ! runuser -u www-data -- test -x "$DATA_DIR"; then
        printf 'NFS permissions failed. Storage administrator must prepare the dedicated data directory for www-data UID/GID %s:%s, mode 0700 or 0750, and allow parent traversal.\n' "$(id -u www-data)" "$(id -g www-data)"
        printf 'Check ACLs, identity mapping, export client allowlist and squash settings. Keep root squash. No server permissions were changed.\n'
        return 1
    fi
    local entry probe
    entry=$(runuser -u www-data -- find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit)
    [[ -z $entry ]] || { printf 'Data directory is not empty. Choose a new dedicated directory; existing data will not be reused.\n'; return 1; }
    probe=$(runuser -u www-data -- mktemp "$DATA_DIR/.nextcloud-write-test.XXXXXXXX")
    runuser -u www-data -- rm -- "$probe"

    STAGE=download-nextcloud
    local work=/var/lib/nextcloud-installer/download base checksum
    mkdir -m 700 "$work"
    base="https://download.nextcloud.com/server/releases/nextcloud-$NC_VERSION.tar.bz2"
    curl --fail --show-error --location --proto '=https' --tlsv1.2 "$base.sha256" -o "$work/archive.sha256"
    checksum=$(awk 'NR == 1 {print $1}' "$work/archive.sha256")
    [[ $checksum =~ ^[a-f0-9]{64}$ ]]
    curl --fail --show-error --location --proto '=https' --tlsv1.2 "$base" -o "$work/archive.tar.bz2"
    printf '%s  %s\n' "$checksum" "$work/archive.tar.bz2" | sha256sum --check --status
    # Archive comes from the official HTTPS origin and must pass its published checksum.
    tar -xjf "$work/archive.tar.bz2" --no-same-owner -C /var/www
    chown -R www-data:www-data /var/www/nextcloud
    # PHP variables must remain literal for PHP to evaluate them.
    # shellcheck disable=SC2016
    php -r 'require "/var/www/nextcloud/version.php"; exit($OC_VersionString !== $argv[1]);' "$NC_VERSION"

    STAGE=database
    cat > /etc/mysql/mariadb.conf.d/60-nextcloud.cnf <<'CNF'
[mysqld]
bind-address = 127.0.0.1
transaction-isolation = READ-COMMITTED
binlog_format = ROW
CNF
    systemctl restart mariadb
    systemctl enable --now redis-server
    # Hex-generated passwords cannot inject SQL; no DB password appears in process arguments.
    mariadb <<SQL
CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'nextcloud'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
SQL
    cat > /etc/php/8.3/mods-available/nextcloud.ini <<'INI'
memory_limit=512M
upload_max_filesize=1024M
post_max_size=1024M
max_execution_time=3600
apc.enable_cli=1
opcache.enable=1
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
INI
    phpenmod nextcloud

    STAGE=nextcloud-initialization
    cd /var/www/nextcloud
    # Secrets are transient in guest process memory/arguments. Nextcloud stores the DB
    # secret in its own restricted config and only a hash of the admin password.
    runuser -u www-data -- php occ maintenance:install --database mysql --database-name nextcloud \
        --database-user nextcloud --database-pass "$DB_PASSWORD" --database-host localhost \
        --admin-user ncadmin --admin-pass "$ADMIN_PASSWORD" --data-dir "$DATA_DIR"
    unset ADMIN_PASSWORD DB_PASSWORD
    occ() { runuser -u www-data -- php /var/www/nextcloud/occ "$@"; }
    occ config:system:set trusted_domains 0 --value "$PUBLIC_HOST"
    occ config:system:set memcache.local --value '\OC\Memcache\APCu'
    occ config:system:set memcache.locking --value '\OC\Memcache\Redis'
    occ config:system:set redis host --value 127.0.0.1
    occ config:system:set redis port --type integer --value 6379
    local scheme=http
    if [[ $PROXY_MODE == yes ]]; then
        scheme=https
        occ config:system:set trusted_proxies 0 --value "$TRUSTED_PROXY"
        occ config:system:set overwriteprotocol --value https
        occ config:system:set overwritehost --value "$PUBLIC_HOST"
    fi
    occ config:system:set overwrite.cli.url --value "$scheme://$PUBLIC_HOST"
    occ config:system:set htaccess.RewriteBase --value /
    occ maintenance:update:htaccess
    occ background:cron
    chmod 640 /var/www/nextcloud/config/config.php

    STAGE=web-and-background-services
    cat > /etc/apache2/sites-available/nextcloud.conf <<APACHE
<VirtualHost *:80>
    ServerName $PUBLIC_HOST
    DocumentRoot /var/www/nextcloud
    <Directory /var/www/nextcloud>
        Require all granted
        AllowOverride All
        Options FollowSymLinks
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>
    <Directory $NFS_MOUNT>
        Require all denied
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/nextcloud-error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud-access.log combined
</VirtualHost>
APACHE
    chmod 644 /etc/apache2/sites-available/nextcloud.conf
    a2dissite 000-default
    a2ensite nextcloud
    a2enmod rewrite headers env dir mime
    local mount_unit
    mount_unit=$(systemd-escape --path --suffix=mount "$NFS_MOUNT")
    mkdir -p /etc/systemd/system/apache2.service.d
    cat > /etc/systemd/system/apache2.service.d/nextcloud-nfs.conf <<UNIT
[Unit]
RequiresMountsFor=$NFS_MOUNT
BindsTo=$mount_unit
After=$mount_unit
[Service]
ExecStartPre=/usr/bin/mountpoint -q $NFS_MOUNT
UNIT
    cat > /etc/systemd/system/nextcloud-cron.service <<UNIT
[Unit]
Description=Nextcloud background jobs
RequiresMountsFor=$NFS_MOUNT
BindsTo=$mount_unit
After=$mount_unit
[Service]
Type=oneshot
User=www-data
ExecStartPre=/usr/bin/mountpoint -q $NFS_MOUNT
ExecStart=/usr/bin/php -f /var/www/nextcloud/cron.php
UNIT
    cat > /etc/systemd/system/nextcloud-cron.timer <<'UNIT'
[Unit]
Description=Nextcloud cron every five minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT
    chmod 644 /etc/systemd/system/nextcloud-cron.* /etc/systemd/system/apache2.service.d/nextcloud-nfs.conf
    systemctl daemon-reload
    apache2ctl configtest
    systemctl enable --now apache2 nextcloud-cron.timer
    occ status
    printf 'complete\n' > /var/lib/nextcloud-installer/status
    trap - ERR
    printf 'Guest configuration complete.\n'
}

guest_setup
