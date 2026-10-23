#!/bin/bash

# 1. Reattach GPU endpoints to host
virsh nodedev-reattach pci_0000_09_00_1
virsh nodedev-reattach pci_0000_09_00_0

# 2. Reload drivers
modprobe nvidia
modprobe nvidia_modeset
modprobe nvidia_uvm
modprobe nvidia_drm

# 3. Restore graphical environment
systemctl isolate graphical.target

# 4. Restore CPU governor
cpupower frequency-set -g powersave