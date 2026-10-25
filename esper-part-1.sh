#!/bin/bash
set -euo pipefail

# Set keyboard map & time sync
loadkeys uk
timedatectl set-ntp true

# Sort the mirrorlist so downloads are fast enough and from teh correct location
reflector --country 'United Kingdom' --protocol https --latest 50 --fastest 8 --age 24 --sort rate --save /etc/pacman.d/mirrorlist

# Create Paritions - NON ENCRYPTED VERSION
parted -s /dev/nvme0n1 mklabel gpt
parted -s /dev/nvme0n1 mkpart ESP fat32 2048s 1GiB
parted -s /dev/nvme0n1 mkpart primary ext4 1GiB 129GiB
parted -s /dev/nvme0n1 mkpart primary ext4 129GiB 100%

parted -s /dev/nvme0n1 set 1 boot on
mkfs.vfat -F32 /dev/nvme0n1p1
mkfs.ext4 /dev/nvme0n1p2
mkfs.ext4 /dev/nvme0n1p3

mount /dev/nvme0n1p2 /mnt
mkdir -p /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot

mkdir -p /mnt/srv/{Games,VMs}
mount /dev/nvme1n1p1 /mnt/srv/Games
mount /dev/nvme0n1p4 /mnt/srv/VMs

# Install base system
pacstrap -K /mnt base base-devel amd-ucode linux linux-firmware linux-headers e2fsprogs zram-generator nvidia-open systemd-resolvconf openssh wget nano git

# Generate fstab using persistent UUIDs
genfstab -U /mnt >> /mnt/etc/fstab

# Enter target environment
arch-chroot /mnt

# Unmount and reboot into installed system
umount -R /mnt
reboot
