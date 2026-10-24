#!/bin/bash
set -euo pipefail

user="user"
hostname="muther"

# Docker config variables
domain="example.com"
radarr_api_key="abcdefg1234567890abcdefg1234567890a"
sonarr_api_key="abcdefg1234567890abcdefg1234567890a"
transmission_user="transmission"
transmission_pass="1234"
wireguard_private_key=""
wireguard_addresses=""
wireguard_server_countries=""
cloudflare_api_token=""

localectl set-keymap uk
timedatectl set-ntp true
hostnamectl set-hostname "$hostname"

# Arch key servers are bad
echo "keyserver hkps://keys.openpgp.org" >> /etc/pacman.d/gnupg/gpg.conf

# Install required packages
pacman -Sy
pacman -S --noconfirm \
  ccache certbot certbot-dns-cloudflare \
  docker docker-compose \
  pacman-contrib podman \
  reflector

# Add user to docker and hardware rendering groups for QuickSync
usermod -aG docker,video,render "$user"

# Configure reflector
cat ./Configs/mirrorupgrade.hook > /etc/pacman.d/hooks/mirrorupgrade.hook

# Optimise AUR compiles
sed -i -e "\
  s/BUILDENV=.*/BUILDENV=(\!distcc color ccache check \!sign)/g; \
  s/#MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/g" \
/etc/makepkg.conf

# Install AUR helper of the month
( cd /tmp || exit 1
su "$user" -P -c 'git clone https://aur.archlinux.org/paru.git'
cd /tmp/paru || exit 1
su "$user" -P -c 'makepkg -si --noconfirm' )

# Set max journal size for systemd-journald
echo "SystemMaxUse=50M" >> /etc/systemd/journald.conf

# Subnet isolation configuration
mkdir -p /etc/docker /etc/containers
cat ./MutherConfigs/daemon.json > /etc/docker/daemon.json
cat ./MutherConfigs/containers.conf > /etc/containers/containers.conf

# Appdata, media directories and environment file
mkdir -p /srv/media/{blackhole,downloads/{incomplete,complete/{tv-sonarr,films-radarr}},films,tv}
mkdir -p /srv/appdata/{nginx/html/.well-known,transmission,sonarr,radarr,jackett}

cat << EOF > /srv/appdata/.env
domain=$domain
radarr_api_key=$radarr_api_key
sonarr_api_key=$sonarr_api_key
transmission_user=$transmission_user
transmission_pass=$transmission_pass
wireguard_private_key=$wireguard_private_key
wireguard_addresses=$wireguard_addresses
wireguard_server_countries=$wireguard_server_countries
EOF
chmod 0600 /srv/appdata/.env

# Deploy Transmission scripts
cat ./MutherConfigs/download-unrar.sh > /srv/appdata/transmission/download-unrar.sh
chmod +x /srv/appdata/transmission/download-unrar.sh

cat ./MutherConfigs/download-cleanup.sh > /srv/appdata/transmission/download-cleanup.sh
sed -i \
  -e "s|transmissionuser='.*'|transmissionuser='$transmission_user'|" \
  -e "s|transmissionpass='.*'|transmissionpass='$transmission_pass'|" \
  /srv/appdata/transmission/download-cleanup.sh
chmod +x /srv/appdata/transmission/download-cleanup.sh

# Deploy compose stack
cat ./MutherConfigs/docker-compose.yml > /srv/appdata/docker-compose.yml

# Nginx config
cat ./MutherConfigs/nginx.conf > /srv/appdata/nginx/nginx.conf
sed -i "s|\$domain|$domain|g" /srv/appdata/nginx/nginx.conf

# Issue TLS Certificate
cat ./MutherConfigs/cloudflare.ini > /etc/letsencrypt/cloudflare.ini
sed -i "s|\$cloudflare_api_token|$cloudflare_api_token|g" /etc/letsencrypt/cloudflare.ini
chmod 600 /etc/letsencrypt/cloudflare.ini

certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 \
  --agree-tos \
  --register-unsafely-without-email \
  -d "$domain"

# Deploy renewal hook to reload Nginx on successful renewal
cat ./MutherConfigs/reload-nginx.sh > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# Container initialisation and config adjustments
( cd /srv/appdata || exit 1
  docker compose up -d
  echo "Waiting 60 seconds for containers to unpack default configs..."
  sleep 60
  docker compose stop transmission sonarr radarr jackett )

# Apply custom URL base and Transmission settings
[ -f /srv/appdata/sonarr/config.xml ] && sed -i "s|<UrlBase>.*</UrlBase>|<UrlBase>/sonarr</UrlBase>|g" /srv/appdata/sonarr/config.xml
[ -f /srv/appdata/radarr/Radarr/config.xml ] && sed -i "s|<UrlBase>.*</UrlBase>|<UrlBase>/radarr</UrlBase>|g" /srv/appdata/radarr/Radarr/config.xml

if [ -f /srv/appdata/jackett/Jackett/ServerConfig.json ]; then
  sed -i \
    -e "s|\"BasePathOverride\":.*|\"BasePathOverride\": \"/jackett\",|" \
    -e "s|\"BaseUrlOverride\":.*|\"BaseUrlOverride\": \"https://$domain\",|" \
    /srv/appdata/jackett/Jackett/ServerConfig.json
fi

if [ -f /srv/appdata/transmission/settings.json ]; then
  sed -i \
    -e 's|"dht-enabled".*|"dht-enabled": false,|' \
    -e 's|"idle-seeding-limit".*|"idle-seeding-limit": 28800,|' \
    -e 's|"idle-seeding-limit-enabled".*|"idle-seeding-limit-enabled": true,|' \
    -e 's|"script-torrent-done-enabled".*|"script-torrent-done-enabled": true,|' \
    -e 's|"script-torrent-done-filename".*|"script-torrent-done-filename": "/config/download-unrar.sh",|' \
    /srv/appdata/transmission/settings.json
fi

# Ensure user ownership across storage
chown -R "$user":"$user" /srv/media /srv/appdata

# Restart the full stack
( cd /srv/appdata || exit 1
  docker compose up -d )

# Systemd timer for Transmission daily cleanup
cat ./MutherConfigs/transmission-cleanup.service > /etc/systemd/system/transmission-cleanup.service
cat ./MutherConfigs/transmission-cleanup.timer > /etc/systemd/system/transmission-cleanup.timer

# Enable services and reboot
systemctl daemon-reload
systemctl enable \
  certbot-renew.timer \
  docker \
  podman.socket \
  fstrim.timer \
  systemd-oomd \
  systemd-timesyncd \
  transmission-cleanup.timer

reboot