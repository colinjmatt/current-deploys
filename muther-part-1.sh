#!/bin/bash
set -euo pipefail

# Set keyboard map & time sync
loadkeys uk
timedatectl set-ntp true

# Sort the mirrorlist so downloads are fast enough and from the correct location
reflector --country 'United Kingdom' --protocol https --latest 50 --fastest 8 --age 24 --sort rate --save /etc/pacman.d/mirrorlist

# Create Partitions - NON ENCRYPTED VERSION
# p1: 1GiB ESP
# p2: 64GiB Arch OS Root (1GiB -> 65GiB)
# p3: Remainder for /srv/appdata (65GiB -> 100%)
parted -s /dev/nvme0n1 mklabel gpt
parted -s /dev/nvme0n1 mkpart "ESP" fat32 2048s 1GiB
parted -s /dev/nvme0n1 set 1 esp on
parted -s /dev/nvme0n1 mkpart "root" ext4 1GiB 65GiB
parted -s /dev/nvme0n1 mkpart "appdata" ext4 65GiB 100%
# sda p1: 100% of /dev/sda for media storage
parted -s /dev/sda mklabel gpt 
parted -s /dev/sda mkpart "media" ext4 0% 100%

# Format filesystems
mkfs.fat -F 32 /dev/nvme0n1p1
mkfs.ext4 -F -L arch_root /dev/nvme0n1p2
mkfs.ext4 -F -L appdata /dev/nvme0n1p3
# Format sda partition for media storage
mkfs.ext4 -F -L -m 0 media /dev/sda1

# Mount target hierarchy
mount /dev/nvme0n1p2 /mnt

mkdir -p /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot

mkdir -p /mnt/srv/appdata
mount /dev/nvme0n1p3 /mnt/srv/appdata

mkdir -p /mnt/srv/media
mount /dev/sda1 /mnt/srv/media

# Install base system
pacstrap -K /mnt base base-devel intel-ucode linux linux-firmware e2fsprogs zram-generator openssh wget nano git

# Generate fstab using persistent UUIDs
genfstab -U /mnt >> /mnt/etc/fstab

# Enter target environment
arch-chroot /mnt

# Unmount and reboot into installed system
umount -R /mnt
reboot
