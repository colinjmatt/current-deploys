#!/bin/bash
set -e

# 1. Isolate multi-user target (shuts down graphical sessions and SDDM cleanly)
systemctl isolate multi-user.target

# 2. Ensure all user sessions holding GPU DRM devices are terminated
sleep 1
fuser -k /dev/nvidia* /dev/dri/* 2>/dev/null || true
sleep 1

# 3. Safely unload NVIDIA modules
modprobe -r nvidia_drm || true
modprobe -r nvidia_modeset || true
modprobe -r nvidia_uvm || true
modprobe -r nvidia || true

# 4. SAFETY CHECK: Abort if NVIDIA is still loaded
if lsmod | grep -q "^nvidia "; then
    echo "ERROR: NVIDIA driver is still in use. Aborting to prevent kernel panic." >&2
    systemctl isolate graphical.target
    exit 1
fi

# 5. Only detach once the GPU is completely idle and unloaded
virsh nodedev-detach pci_0000_09_00_0
virsh nodedev-detach pci_0000_09_00_1

# 6. Maximize CPU performance
cpupower frequency-set -g performance

sleep 5