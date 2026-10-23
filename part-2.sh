#!/bin/bash
set -euo pipefail

hostname="esper"
user="user"
sshuser="sshuser"

# Set region, locale and time synchronisation
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc
sed -i \
  -e '/^#en_GB\.UTF-8/s/^#//' \
  -e '/^#en_US\.UTF-8/s/^#//' \
  /etc/locale.gen
locale-gen

echo "LANG=en_GB.UTF-8" > /etc/locale.conf
echo "KEYMAP=uk" > /etc/vconsole.conf

# Create dhcp ethernet connection
cat ./Configs/20-ethernet-dhcp.network > /etc/systemd/network/20-ethernet-dhcp.network
interface="$(ip -o link | grep "state UP" | awk -F': ' '{print $2}')"
sed -i "s|\$interface|$interface|g" /etc/systemd/network/20-ethernet-dhcp.network

# Set hostname
echo "$hostname" > /etc/hostname
echo "127.0.0.1 localhost.localdomain localhost $hostname" > /etc/hosts

# Set .bashrc and .nanorc for users & root
cat ./Configs/root_bashrc > /root/.bashrc
cat ./Configs/user_bashrc > /etc/skel/.bashrc
cat ./Configs/root_nanorc > /root/.nanorc
cat ./Configs/user_nanorc > /etc/skel/.nanorc
cat ./Configs/nanorc > /etc/nanorc

# Set root password and create user
passwd root
groupadd -r autologin
useradd -m -U -G wheel,autologin "$user"
passwd "$user"

# Configure sudoers drop-in
echo "$sshuser ALL=(ALL) ALL, NOPASSWD: /usr/bin/pacman, /usr/bin/shutdown, /usr/bin/reboot, /usr/bin/virsh" > /etc/sudoers.d/"$sshuser"
chmod 0440 /etc/sudoers.d/"$sshuser"

# Suppress msrs messages
echo "options kvm report_ignored_msrs=0" > /etc/modprobe.d/kvm.conf

# Update mkinitcpio.conf
sed -i \
  -e 's|^MODULES=.*|MODULES=(ext4 nvidia nvidia_modeset nvidia_uvm nvidia_drm vfio_pci vfio vfio_iommu_type1)|' \
  /etc/mkinitcpio.conf

# Limit presets to default and regenerate initramfs
sed -i "s|^PRESETS=.*|PRESETS=('default')|" /etc/mkinitcpio.d/linux.preset
mkinitcpio -P

# Configure pacman
sed -i \
  -e 's|^#Color|Color|' \
  -e 's|^ParallelDownloads = .*|ParallelDownloads = 10|' \
  /etc/pacman.conf
sed -i '/^#\[multilib\]/{n;s|^#||;x;d;x}' /etc/pacman.conf
sed -i 's|^#\[multilib\]|\[multilib\]|' /etc/pacman.conf

mkdir -p /etc/pacman.d/hooks/
cat ./Configs/paccache.hook > /etc/pacman.d/hooks/paccache.hook
cat ./Configs/paccache.sh > /usr/local/bin/paccache.sh
sed -i "s|\$user|$user|g" /usr/local/bin/paccache.sh
chmod +x /usr/local/bin/paccache.sh

# Setup bootloader and hooks
bootctl install
cat ./EsperConfigs/nvidia.hook > /etc/pacman.d/hooks/nvidia.hook
cat ./Configs/loader.conf > /boot/loader/loader.conf
cat ./EsperConfigs/arch.conf > /boot/loader/entries/arch.conf

rootuuid=$(blkid -s UUID -o value /dev/nvme0n1p2)
sed -i "s/\$rootuuid/$rootuuid/g" /boot/loader/entries/arch.conf

# Configure quiet boot (service drop-ins and sysctl printk)
mkdir -p /etc/systemd/system/systemd-fsck-root.service.d/
mkdir -p /etc/systemd/system/systemd-fsck@.service.d/
cat ./EsperConfigs/quiet.conf > /etc/systemd/system/systemd-fsck-root.service.d/quiet.conf
cat ./EsperConfigs/quiet.conf > /etc/systemd/system/systemd-fsck@.service.d/quiet.conf
cat ./EsperConfigs/99-printk.conf > /etc/sysctl.d/99-printk.conf

# Configure SSH drop-in
cat ./Configs/10-custom.conf > /etc/ssh/sshd_config.d/10-custom.conf
sed -i "s|\$sshuser|$sshuser|g" /etc/ssh/sshd_config.d/10-custom.conf
chmod 0600 /etc/ssh/sshd_config.d/10-custom.conf

# Setup SSH key directory with strict permissions
mkdir -p /home/"$user"/.ssh
chmod 0700 /home/"$user"/.ssh
chown "$user":"$user" /home/"$user"/.ssh

read -n 1 -s -r -p "Switch to another TTY and add the SSH key for $sshuser. Press any key to continue..."
echo ""

# Ensure correct ownership and permissions on created authorized_keys
if [ -f "/home/$user/.ssh/authorized_keys" ]; then
    chmod 0600 "/home/$user/.ssh/authorized_keys"
    chown "$user":"$user" "/home/$user/.ssh/authorized_keys"
fi

# Configure zram
echo "[zram0]" > /etc/systemd/zram-generator.conf

# Point resolv.conf to systemd-resolved stub listener
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Enable networking, DNS, bootloader updater, and SSH
systemctl enable \
  systemd-boot-update \
  systemd-networkd \
  systemd-resolved \
  sshd

# Exit chroot
exit