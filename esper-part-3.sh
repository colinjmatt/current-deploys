#!/bin/bash
set -euo pipefail

user="user"
hostname="esper"
domain="x.local"
ipaddress="192.168.1.101"
dns="192.168.1.1"
gateway="192.168.1.1"
printerip="192.168.1.120"

localectl set-keymap uk
timedatectl set-ntp true
hostnamectl set-hostname "$hostname"

# Arch key servers are bad
echo "keyserver hkps://keys.openpgp.org" >> /etc/pacman.d/gnupg/gpg.conf

# All currently required software in official repos
pacman -Sy
pacman -S --noconfirm \
  alsa-plugins alsa-utils \
  bluez bluez-utils \
  ccache code cpupower cups cups-pdf \
  discord djvulibre dmidecode dosfstools \
  edk2-ovmf exfatprogs \
  fastfetch ffmpegthumbs ffnvcodec-headers firefox fuse2 \
  helvum hidapi htop hunspell-en_gb \
  i2c-tools \
  kdeconnect kdenetwork-filesharing kdegraphics-thumbnailers kde-applications-meta kde-gtk-config \
  libreoffice-fresh libva-utils libva-nvidia-driver libvdpau-va-gl libxcrypt-compat libxnvctrl libvirt \
  nvidia-open nvidia-settings net-tools network-manager-applet networkmanager networkmanager-openvpn \
  noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ntfs-3g \
  openrgb \
  p7zip pacman-contrib phonon-qt6-vlc pigz pipewire pipewire-alsa pipewire-jack pipewire-pulse pipewire-zeroconf \
  plasma-login-manager plasma-browser-integration plasma-meta \
  powerdevil power-profiles-daemon print-manager python-hid python-psutil python-pyusb \
  qemu-desktop qt5-svg qt5-wayland \
  reflector rsync \
  sane sddm-kcm sonnet sshfs swtpm system-config-printer sysstat \
  tesseract tesseract-data-eng ttf-liberation \
  unrar unzip usbutils \
  virt-manager \
  wmctrl \
  xdg-desktop-portal xdg-desktop-portal-gtk \
  zip

# Configure reflector
cat ./Configs/mirrorupgrade.hook > /etc/pacman.d/hooks/mirrorupgrade.hook

# Optimise AUR compiles
sed -i -e "\
  s/BUILDENV=.*/BUILDENV=(\!distcc color ccache check \!sign)/g; \
  s/#MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/g" \
/etc/makepkg.conf

# Install AUR helper of the month (as a non-priviledged user) and install AUR software
( cd /tmp || exit 1
su "$user" -P -c 'git clone https://aur.archlinux.org/paru.git'
cd /tmp/paru || exit 1
su "$user" -P -c 'makepkg -si --noconfirm; \
  paru -S --noconfirm \
  brother-dcp-9020cdw brscan4 \
  dwproton-bin \
  github-desktop gnome-icon-theme gnome-icon-theme-extras gnome-icon-theme-symbolic \
  headsetcontrol headsetkontrol heroic-games-launcher-bin \
  numix-circle-icon-theme-git numix-icon-theme-git \
  protontricks proton-ge-custom-bin protonup-qt-bin \
  steamtinkerlaunch sunshine \
  ttf-ms-fonts \
  uxplay \
  virtio-win' )

# Steam
pacman -S --noconfirm \
  lib32-fontconfig lib32-gamemode lib32-libnm lib32-mesa lib32-mesa-utils lib32-nvidia-utils lib32-systemd steam
mkdir -p /home/"$user"/.local/share/Steam/
echo "unShaderBackgroundProcessingThreads $(nproc)" > /home/"$user"/.local/share/Steam/steam_dev.cfg
chown -R "$user":"$user" /home/"$user"/.local
su "$user" -P -c 'steamtinkerlaunch compat add'

# Blacklist nouveau
cat ./EsperConfigs/blacklist-nouveau.conf > /etc/modprobe.d/blacklist-nouveau.conf

# Gaming enhancements
cat ./EsperConfigs/90-vm-and-scheduler.conf > /etc/tmpfiles.d/90-vm-and-scheduler.conf

# Setup scanner
echo "$printerip" >> /etc/sane.d/net.conf
brsaneconfig4 -a name=BROTHER-DCP-9020CDW model=DCP-9020CDW ip="$printerip"

# Set user to autologin
mkdir -p /etc/sddm.conf.d/
cat ./EsperConfigs/sddm-autologin.conf > /etc/sddm.conf.d/autologin.conf
sed -i "s/User=.*/User=""$user""/g" /etc/sddm.conf.d/autologin.conf

# Configure QEMU and libvirt
cat ./EsperConfigs/qemu.conf >> /etc/libvirt/qemu.conf
sed -i -e "s/\user.*/user\ =\ \"""$user""\"/g" /etc/libvirt/qemu.conf
usermod -a -G input,kvm,libvirt,render "$user"

mkdir -p /etc/libvirt/{devices,storage/autostart,hooks,qemu/networks/autostart}

# CPU set to performance and GPU preparation via hooks
cat ./EsperConfigs/qemu > /etc/libvirt/hooks/qemu
chmod +x /etc/libvirt/hooks/qemu
mkdir -p /etc/libvirt/hooks/qemu.d/win-gaming/prepare/begin/
mkdir -p /etc/libvirt/hooks/qemu.d/win-gaming/release/end/
cat ./EsperConfigs/libvirt-start.sh > /etc/libvirt/hooks/qemu.d/win-gaming/prepare/begin/start.sh
cat ./EsperConfigs/libvirt-end.sh > /etc/libvirt/hooks/qemu.d/win-gaming/release/end/end.sh
chmod -R +x /etc/libvirt/hooks/

# Disable sp5100 watchdog
cat ./EsperConfigs/blacklist-sp5100-watchdog.conf > /etc/modprobe.d/blacklist-sp5100-watchdog.conf

# Storage options for virt-manager
cat ./EsperConfigs/Virtio.xml > /etc/libvirt/storage/Virtio.xml
cat ./EsperConfigs/Windows.xml > /etc/libvirt/storage/Windows.xml
ln -sf /etc/libvirt/storage/Virtio.xml /etc/libvirt/storage/autostart/Virtio.xml
ln -sf /etc/libvirt/storage/Windows.xml /etc/libvirt/storage/autostart/Windows.xml

# VM Network
cat ./EsperConfigs/libvirt-default.xml > /etc/libvirt/qemu/networks/default.xml
ln -sf /etc/libvirt/qemu/networks/default.xml /etc/libvirt/qemu/networks/autostart/default.xml

# VM configs
cat ./EsperConfigs/win-gaming.xml > /etc/libvirt/qemu/win-gaming.xml
cat ./EsperConfigs/win-work.xml > /etc/libvirt/qemu/win-work.xml

# Create SSL keys for Spice
mkdir -p /etc/pki/qemu
( cd /etc/pki/qemu || exit 1
openssl genrsa -out ca-key.pem 2048
openssl req -new -x509 -days 750 -key ca-key.pem -out ca-cert.pem -utf8 -subj "/CN=Self Signed"
openssl genrsa -out server-key.pem 2048
openssl req -new -key server-key.pem -out server-key.csr -utf8 -subj "/CN=$user"
openssl x509 -req -days 750 -in server-key.csr -CA ca-cert.pem -CAkey ca-key.pem -set_serial 01 -out server-cert.pem
chown root:kvm ./*
chmod 0440 ./* )

# Configure NetworkManager
uuid="$(cat /proc/sys/kernel/random/uuid)"
install -d -m 700 /etc/NetworkManager/system-connections
install -m 600 ./EsperConfigs/host-bridge.nmconnection /etc/NetworkManager/system-connections/host-bridge.nmconnection

sed -i \
  -e "s|\$uuid|$uuid|g" \
  -e "s|\$ipaddress|$ipaddress|g" \
  -e "s|\$gateway|$gateway|g" \
  -e "s|\$dns|$dns|g" \
  -e "s|\$domain|$domain|g" \
  /etc/NetworkManager/system-connections/host-bridge.nmconnection

# Make autostart directory if it doesn't exist
mkdir -p /home/"$user"/.config/autostart

# Disable audio power saving
tee /etc/modprobe.d/audio_powersave.conf << 'EOF'
options snd_hda_intel power_save=0 power_save_controller=N
EOF

# Headset Control
cat ./EsperConfigs/Arctis7PlusChatMix.py > /usr/local/bin/Arctis7PlusChatMix.py
cat ./EsperConfigs/99-arctis7plus.rules > /etc/udev/rules.d/99-arctis7plus.rules
sed -i -e "s/\$user/""$user""/g" /etc/udev/rules.d/99-arctis7plus.rules
cat ./EsperConfigs/Arctis7PlusChatMix.desktop > /home/"$user"/.config/autostart/Arctis7PlusChatMix.desktop

# OpenRGB
cat ./EsperConfigs/60-openrgb.rules > /etc/udev/rules.d/60-openrgb.rules
cat ./EsperConfigs/OpenRGB.desktop > /home/"$user"/.config/autostart/OpenRGB.desktop
mkdir -p /home/"$user"/.config/OpenRGB
cat ./EsperConfigs/openrgb-Default.orp > /home/"$user"/.config/OpenRGB/openrgb-Default.orp

# Steam friends list positioning
cat ./EsperConfigs/SteamFriendsListPosition.desktop > /home/"$user"/.config/autostart/SteamFriendsListPosition.desktop
cat ./EsperConfigs/wmctl-friendslist.sh > /usr/local/bin/wmctl-friendslist.sh

# Sunshine
cat ./EsperConfigs/Sunshine.desktop > /home/"$user"/.config/autostart/Sunshine.desktop

# UXPlay
cat ./EsperConfigs/UXPlay.desktop > /home/"$user"/.config/autostart/UXPlay.desktop

# Yakuake
cat ./EsperConfigs/Yakuake.desktop > /home/"$user"/.config/autostart/Yakuake.desktop

# Discord
ln -sf /usr/share/applications/discord.desktop /home/"$user"/.config/autostart/discord.desktop

# Set permissions
chmod +x -R /usr/local/bin/*
chown -R "$user":"$user" /home/"$user"/.config /home/"$user"/.local

# Set max journal size for systemd-journald
echo "SystemMaxUse=50M" >> /etc/systemd/journald.conf

# Disable systemd-networkd for handoff on reboot (does not drop current SSH session)
systemctl disable \
  systemd-networkd \
  systemd-resolved

# Enable ALL the services
systemctl enable \
  avahi-daemon \
  bluetooth \
  cpupower \
  cups \
  fstrim.timer \
  libvirtd \
  NetworkManager \
  nvidia-persistenced \
  sddm \
  systemd-oomd \
  systemd-timesyncd \
  virtlogd.socket 

reboot