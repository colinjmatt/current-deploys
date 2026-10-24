#!/bin/bash
# ==============================================================================
# Setup Script: Zabbix Monitoring Stack on Arch Linux ARM (LXC)
# Target Architecture: armv7l / aarch64 (Turris Omnia LXC)
# Stack: PostgreSQL 16+, PHP-FPM, Nginx, Zabbix Server, Zabbix Agent 2
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Network Configuration (systemd-networkd)
# ------------------------------------------------------------------------------
# Define a persistent static IPv4 address, gateway, and DNS on eth0.
cat << 'EOF' > /etc/systemd/network/eth0.network
[Match]
Name=eth0

[Network]
Address=192.168.1.130/24
Gateway=192.168.1.1
DNS=192.168.1.1
EOF

# Remove default dynamic/DHCP network configurations to prevent race conditions
rm -f /etc/systemd/network/eth.network /etc/systemd/network/en.network

# ------------------------------------------------------------------------------
# 2. Package Manager Initialization & System Updates
# ------------------------------------------------------------------------------
# Disable pacman's download sandbox (seccomp filters often fail inside unprivileged LXC)
sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

# Initialize and populate the Arch Linux ARM trust database
pacman-key --init
pacman-key --populate archlinuxarm

# Synchronize repositories, perform a system upgrade, and install the Zabbix stack
pacman -Syu --noconfirm
pacman -S --noconfirm \
    postgresql \
    zabbix-server \
    zabbix-frontend-php \
    zabbix-agent2 \
    fping \
    nginx \
    php-fpm \
    php-gd \
    php-pgsql \
    sudo

# ------------------------------------------------------------------------------
# 3. System Localization, Timezone & Hostname
# ------------------------------------------------------------------------------
# Set local timezone to Europe/London
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime

# Generate en_GB locale and set system default
sed -i -e "s/\#en_GB.UTF-8\ UTF-8/en_GB.UTF-8\ UTF-8/g" /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf

# Set console keymap and enable NTP synchronization via systemd-timesyncd
localectl set-keymap uk
timedatectl set-ntp true

# Set hostname and update /etc/hosts for local loopback resolution
hostnamectl set-hostname "zabbix"
echo "zabbix" > /etc/hostname
echo "127.0.0.1 localhost.localdomain localhost zabbix" > /etc/hosts

# ------------------------------------------------------------------------------
# 4. PHP Configuration for Zabbix Frontend
# ------------------------------------------------------------------------------
# Enable required extensions, set execution/upload constraints, and set timezone
sed -i -e "\
  s/\;extension=bcmath/extension=bcmath/g; \
  s/\;extension=gd/extension=gd/g; \
  s/\;extension=gettext/extension=gettext/g; \
  s/\;extension=ldap/extension=ldap/g; \
  s/\;extension=mysqli/extension=pgsql/g; \
  s/\;extension=sockets/extension=sockets/g; \
  s/post_max_size\ =\ .*/post_max_size\ =\ 16M/g; \
  s/max_execution_time\ =\ .*/max_execution_time\ =\ 300/g; \
  s/max_input_time\ =\ .*/max_input_time\ =\ 300/g; \
  s/;date.timezone\ =/date.timezone\ =\ \"Europe\/London\"/g" \
/etc/php/php.ini

# ------------------------------------------------------------------------------
# 5. PostgreSQL Database Cluster Setup
# ------------------------------------------------------------------------------
# Initialize the database cluster with matching system locale and UTF-8 encoding
su postgres -P -c 'initdb --locale=en_GB.UTF-8 -E UTF8 -D /var/lib/postgres/data'

# Start PostgreSQL temporarily to provision the user, database, and schemas
systemctl start postgresql

# Create dedicated Zabbix database user and owned database
su - postgres -c "psql -c \"CREATE USER zabbix WITH PASSWORD 'zabbix';\""
# Grant pg_monitor and WAL inspection privileges
su - postgres -c "psql -c \"GRANT pg_monitor TO zabbix;\""
su - postgres -c "psql -c \"GRANT EXECUTE ON FUNCTION pg_ls_waldir() TO zabbix;\""
su - postgres -c "psql -c \"CREATE DATABASE zabbix OWNER zabbix ENCODING 'UTF8';\""

# Import initial database schema, images, and seed dataset
su - postgres -c "cat /usr/share/zabbix-server/postgresql/schema.sql | psql -d zabbix"
su - postgres -c "cat /usr/share/zabbix-server/postgresql/images.sql | psql -d zabbix"
su - postgres -c "cat /usr/share/zabbix-server/postgresql/data.sql | psql -d zabbix"

# Symlink Zabbix web application to the standard Arch web directory
mkdir -p /srv/http
ln -sfn /usr/share/webapps/zabbix /srv/http/zabbix

# ------------------------------------------------------------------------------
# 6. Zabbix Server Configuration
# ------------------------------------------------------------------------------
# Set database password for the Zabbix daemon connection
sed -i -e "s/\#\ DBPassword=/DBPassword=zabbix/g" /etc/zabbix/zabbix_server.conf

# ------------------------------------------------------------------------------
# 7. Build & Install Zabbix Agent 2 PostgreSQL Plugin
# ------------------------------------------------------------------------------
# Install temporary build dependencies
pacman -S --noconfirm --needed go

# Clone and compile the standalone loadable plugin for Agent 2
rm -rf /tmp/zabbix-plugin-postgresql
git clone --depth 1 --branch release/7.4 https://git.zabbix.com/scm/ap/postgresql.git /tmp/zabbix-plugin-postgresql || \
git clone --depth 1 https://git.zabbix.com/scm/ap/postgresql.git /tmp/zabbix-plugin-postgresql

(
    cd /tmp/zabbix-plugin-postgresql
    go build -o /usr/bin/zabbix-agent2-plugin-postgresql
)

# Prune build artifacts and Go to recover container storage
rm -rf /tmp/zabbix-plugin-postgresql
pacman -Rns --noconfirm go

# Configure the loadable plugin session using the existing zabbix DB credentials
mkdir -p /etc/zabbix/zabbix_agent2.d/plugins.d
cat << 'EOF' > /etc/zabbix/zabbix_agent2.d/plugins.d/postgresql.conf
Plugins.PostgreSQL.System.Path=/usr/bin/zabbix-agent2-plugin-postgresql

Plugins.PostgreSQL.Sessions.Local.Uri=tcp://127.0.0.1:5432
Plugins.PostgreSQL.Sessions.Local.User=zabbix
Plugins.PostgreSQL.Sessions.Local.Password=zabbix
Plugins.PostgreSQL.Sessions.Local.Database=zabbix
EOF

# ------------------------------------------------------------------------------
# 8. Zabbix Agent 2 Configuration & Custom UserParameters
# ------------------------------------------------------------------------------
# Ensure modular plugin and custom config directories are included in zabbix_agent2.conf
grep -q '^Include=/etc/zabbix/zabbix_agent2.d/\*\.conf' /etc/zabbix/zabbix_agent2.conf || \
  echo 'Include=/etc/zabbix/zabbix_agent2.d/*.conf' >> /etc/zabbix/zabbix_agent2.conf

grep -q '^Include=/etc/zabbix/zabbix_agent2.d/plugins.d/\*\.conf' /etc/zabbix/zabbix_agent2.conf || \
  echo 'Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf' >> /etc/zabbix/zabbix_agent2.conf

# Add custom UserParameter to monitor pending Arch Linux package updates
echo 'UserParameter=archlinuxupdates,checkupdates | wc -l' > /etc/zabbix/zabbix_agent2.d/archlinuxupdates.conf

# ------------------------------------------------------------------------------
# 9. Web Server Configuration (Nginx & PHP-FPM)
# ------------------------------------------------------------------------------
# Configure Nginx to serve the PHP frontend and pass SSL termination headers
# from the upstream Lighttpd reverse proxy on the Turris Omnia host.
cat << 'EOF' > /etc/nginx/nginx.conf
user http;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 80 default_server;
        server_name _;
        root /usr/share/webapps/zabbix;
        index index.php;

        client_max_body_size 16M;

        location / {
            try_files $uri $uri/ =404;
        }

        location ~ \.php$ {
            fastcgi_pass unix:/run/php-fpm/php-fpm.sock;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;

            # Inform PHP that client SSL was terminated upstream at the Omnia host proxy
            fastcgi_param HTTPS on;
            fastcgi_param HTTP_X_FORWARDED_PROTO https;
        }

        # Restrict direct web access to sensitive Zabbix configuration files
        location ~ /(conf|app|include|local)/ {
            deny all;
            return 404;
        }
    }
}
EOF

# ------------------------------------------------------------------------------
# 10. Zabbix Agent 2 PSK Encryption
# ------------------------------------------------------------------------------
# Generate a 256-bit pre-shared key (PSK) and lock down file permissions
openssl rand -hex 32 > /etc/zabbix/zabbix_agent2.psk
chown zabbix:zabbix /etc/zabbix/zabbix_agent2.psk
chmod 640 /etc/zabbix/zabbix_agent2.psk

# Enforce PSK encryption for all agent-server communications in zabbix_agent2.conf
cat << 'EOF' >> /etc/zabbix/zabbix_agent2.conf
TLSConnect=psk
TLSAccept=psk
TLSPSKFile=/etc/zabbix/zabbix_agent2.psk
TLSPSKIdentity=PSK001
EOF

# ------------------------------------------------------------------------------
# 11. System Logging & Service Initialization
# ------------------------------------------------------------------------------
# Cap journald disk usage to 50MB to protect NVMe storage and container RAM
echo "SystemMaxUse=50M" >> /etc/systemd/journald.conf

# Enable and immediately start all services in the stack
systemctl enable \
  postgresql \
  zabbix-server-pgsql \
  zabbix-agent2 \
  nginx \
  php-fpm \
  --now