#!/bin/bash
set -euo pipefail

# --- Target disk selection ---

# WARNING: make sure you don't have a virtual media mounted via the BMC as that
# will appear as the first device.
target=""
for disk in /dev/disk/by-path/pci-*; do
    [ -e "${disk}" ] || continue
    resolved=$(readlink -f "${disk}")
    devtype=$(lsblk -dn -o TYPE "${resolved}")
    [ "${devtype}" = "disk" ] || continue
    target="${resolved}"
    break
done

if [ -z "${target}" ]; then
    echo "error: no disk found under /dev/disk/by-path/pci-*" >&2
    exit 1
fi

echo "Installing to ${target}"

# --- Clean EFI boot entries ---

for entry in $(efibootmgr | awk '$NF ~ /^HD/ { print $1 }' | sed 's/Boot\([0-9A-F]*\)./\1/'); do
    echo "Removing EFI boot entry ${entry}"
    efibootmgr -B -b "${entry}" > /dev/null
done

# --- Wipe and partition ---

REPART_DIR=$(mktemp -d)
trap 'rm -rf "${REPART_DIR}"' EXIT

cat > "${REPART_DIR}/00-esp.conf" <<EOF
[Partition]
Type=esp
Format=vfat
SizeMinBytes=512M
SizeMaxBytes=512M
Label=ESP
MountPoint=/efi
EOF

cat > "${REPART_DIR}/10-root.conf" <<EOF
[Partition]
Type=root
Format=ext4
SizeMinBytes=20G
CopyFiles=/
CopyFiles=/boot
Label=ROOT
MountPoint=/
EOF

systemd-repart \
    --empty=force \
    --definitions="${REPART_DIR}" \
    --discard=false \
    --json=pretty \
    --dry-run=off \
    --copy-source=/ \
    "${target}"

udevadm settle

# --- Post-install configuration ---

mount /dev/disk/by-label/ROOT "/mnt"
mount /dev/disk/by-label/ESP  "/mnt/efi"

cat > "/mnt/etc/fstab" <<EOF
LABEL=ROOT      /               ext4            errors=remount-ro 0       1
LABEL=ESP       /efi            vfat            umask=0077        0       1
EOF

# Reset first-boot condition.
echo "uninitialized" > "/mnt/etc/machine-id"
# Reset on-disk to be a regular bootable system.
rm -f "/mnt/etc/initrd-release"

# Carry over the running cmdline (console, hugepages, ...) and add the
# root argument. This file is the single source of truth: the kexec below
# appends it verbatim and it is picked up for the BLS entries of kernels
# installed later (90-loaderentry reads /etc/kernel/cmdline).
mkdir -p "/mnt/etc/kernel"
printf '%s root=LABEL=ROOT\n' "$(cat /proc/cmdline)" > "/mnt/etc/kernel/cmdline"

# --- Install bootloader ---

mount -t proc proc                     "/mnt/proc"
mount -t sysfs sysfs                   "/mnt/sys"
mount --bind /dev                      "/mnt/dev"
mount --bind /sys/firmware/efi/efivars "/mnt/sys/firmware/efi/efivars"

kver=$(ls /mnt/usr/lib/modules/ | head -1)

chroot "/mnt" bootctl install
chroot "/mnt" update-initramfs -c -k "${kver}"

# --- Execute the kernel from disk ---
kexec -l "/mnt/boot/vmlinuz-${kver}" \
    --initrd="/mnt/boot/initrd.img-${kver}" \
    --append="$(cat /mnt/etc/kernel/cmdline)"
kexec -e
