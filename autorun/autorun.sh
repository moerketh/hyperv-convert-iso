#!/bin/bash
set -e

# Detect disks: new (empty, no partitions) and old (has partitions)
disks=$(ls /dev/sd? | grep -E '^/dev/sd[a-z]$' | sort)
new_disk=""
old_disk=""
for disk in $disks; do
  part_count=$(lsblk -l -o NAME -n $disk | wc -l)
  if [ $part_count -eq 1 ]; then
    new_disk=$disk
  else
    old_disk=$disk
  fi
done

if [ -z "$new_disk" ] || [ -z "$old_disk" ]; then
  echo "Could not detect new (empty) or old disk. Aborting." | tee -a /tmp/error.log
  exit 1
fi

# Fallback to size if detection ambiguous
new_size=$(blockdev --getsz $new_disk)
old_size=$(blockdev --getsz $old_disk)
if (( new_size < old_size )); then
  # Swap if sizes don't match expected
  temp=$new_disk
  new_disk=$old_disk
  old_disk=$temp
fi

echo "New disk: $new_disk (size $new_size sectors), Old disk: $old_disk (size $old_size sectors)" | tee -a /tmp/detection.log

# Partition new disk (GPT with ESP and root)
sgdisk --zap-all $new_disk
sgdisk --new=1:2048:+512M --typecode=1:ef00 --change-name=1:ESP $new_disk  # ESP
sgdisk --new=2::0 --typecode=2:8300 --change-name=2:root $new_disk         # Root (rest, combined boot/root)
partprobe $new_disk

# Format partitions
sleep 1
mkfs.vfat -F32 ${new_disk}1
mkfs.ext4 ${new_disk}2

# Detect partitions on old_disk
echo "Detecting partitions on $old_disk" | tee -a /tmp/clone.log

partitions=$(lsblk -lpno NAME,TYPE $old_disk | grep ' part$' | awk '{print $1}')

temp_check="/tmp/check_root"
mkdir -p "$temp_check"

root_part=""
esp_device=""
boot_device=""
root_found=false

for part in $partitions; do
  fs_type=$(blkid -o value -s TYPE "$part")

  if [[ ! "$fs_type" =~ ^ext[234]$ ]]; then
    continue
  fi

  # Temporarily mount to check if it's root
  if mount -o ro "$part" "$temp_check" 2>/dev/null; then
    if [ -f "$temp_check/etc/fstab" ] && [ -d "$temp_check/bin" ]; then
      root_found=true
      root_part="$part"
      echo "Detected root partition: $root_part (fs: $fs_type)"

      # Parse fstab for /boot and /boot/efi
      esp_device=$(awk '$2 == "/boot/efi" {print $1}' "$temp_check/etc/fstab")
      if [ ! -z "$esp_device" ]; then
        echo "Detected ESP mount in fstab: $esp_device"
      fi

      boot_device=$(awk '$2 == "/boot" {print $1}' "$temp_check/etc/fstab")
      if [ ! -z "$boot_device" ]; then
        echo "Detected separate /boot mount in fstab: $boot_device"
      fi

      umount "$temp_check"
      break  # Assume only one root
    fi
    umount "$temp_check"
  fi
done

rmdir "$temp_check"

if ! $root_found; then
  echo "Error: No valid root partition found on $old_disk."
  exit 1
fi

# Resolve esp_part if esp_device present
esp_part=""
old_esp_uuid=""
old_esp_label=""
if [ ! -z "$esp_device" ]; then
  if [[ "$esp_device" == UUID=* ]]; then
    uuid="${esp_device#UUID=}"
    esp_part=$(blkid -U "$uuid")
    old_esp_uuid="$uuid"
  elif [[ "$esp_device" == LABEL=* ]]; then
    label="${esp_device#LABEL=}"
    esp_part=$(blkid -L "$label")
    old_esp_label="$label"
  elif [[ "$esp_device" == /dev/* ]]; then
    # Remap device to current old_disk if necessary
    if [[ "$esp_device" == ${old_disk}* ]]; then
      esp_part="$esp_device"
    else
      # Original device uses different letter; remap to old_disk
      part_num=$(echo "$esp_device" | sed 's/^\/dev\/sd[a-z]\([0-9]*\)$/\1/')
      esp_part="${old_disk}${part_num}"
      echo "Remapped ESP device from $esp_device to $esp_part"
    fi
    old_esp_uuid=$(blkid -s UUID -o value "$esp_part")
  fi
  if [ -z "$esp_part" ]; then
    echo "Warning: Could not resolve ESP partition from $esp_device. Skipping clone."
  else
    fs_type=$(blkid -o value -s TYPE "$esp_part")
    if [ "$fs_type" != "vfat" ]; then
      echo "Warning: ESP partition $esp_part is not vfat. Skipping clone."
      esp_part=""
    fi
  fi
fi

# Resolve boot_part if boot_device present
boot_part=""
old_boot_uuid=""
old_boot_label=""
if [ ! -z "$boot_device" ]; then
  if [[ "$boot_device" == UUID=* ]]; then
    uuid="${boot_device#UUID=}"
    boot_part=$(blkid -U "$uuid")
    old_boot_uuid="$uuid"
  elif [[ "$boot_device" == LABEL=* ]]; then
    label="${boot_device#LABEL=}"
    boot_part=$(blkid -L "$label")
    old_boot_label="$label"
  elif [[ "$boot_device" == /dev/* ]]; then
    # Remap device to current old_disk if necessary
    if [[ "$boot_device" == ${old_disk}* ]]; then
      boot_part="$boot_device"
    else
      # Original device uses different letter; remap to old_disk
      part_num=$(echo "$boot_device" | sed 's/^\/dev\/sd[a-z]\([0-9]*\)$/\1/')
      boot_part="${old_disk}${part_num}"
      echo "Remapped boot device from $boot_device to $boot_part"
    fi
    old_boot_uuid=$(blkid -s UUID -o value "$boot_part")
  fi
  if [ -z "$boot_part" ]; then
    echo "Warning: Could not resolve /boot partition from $boot_device. Skipping merge."
  else
    fs_type=$(blkid -o value -s TYPE "$boot_part")
    if [[ ! "$fs_type" =~ ^ext[234]$ ]]; then
      echo "Warning: /boot partition $boot_part is not ext*. Skipping merge."
      boot_part=""
    fi
  fi
fi

# Clone root
echo "Cloning root from $root_part to ${new_disk}2"
partclone.ext4 --force --dev-to-dev --source $root_part --output ${new_disk}2 2>&1

# Clone ESP if detected
if [ ! -z "$esp_part" ]; then
  echo "Cloning ESP from $esp_part to ${new_disk}1"
  partclone.vfat --force --dev-to-dev --source $esp_part --output ${new_disk}1 2>&1
else
  echo "No ESP detected on old disk (new ESP will be populated by grub-install)."
fi

# Mount new root and ESP
mkdir -p /mnt/new
mount ${new_disk}2 /mnt/new
mkdir -p /mnt/new/boot/efi
mount ${new_disk}1 /mnt/new/boot/efi

# Merge separate /boot if detected
if [ ! -z "$boot_part" ]; then
  echo "Merging /boot from $boot_part into /mnt/new/boot/"
  temp_old_boot="/tmp/old_boot"
  mkdir -p "$temp_old_boot"
  mount $boot_part "$temp_old_boot"
  rsync -av "$temp_old_boot/" /mnt/new/boot/
  umount "$temp_old_boot"
  rmdir "$temp_old_boot"
fi

# Update fstab with new UUIDs
fstab_path="/mnt/new/etc/fstab"
echo "Updating fstab at $fstab_path"

old_root_uuid=$(blkid -s UUID -o value $root_part)
new_esp_uuid=$(blkid -s UUID -o value ${new_disk}1)
new_root_uuid=$(blkid -s UUID -o value ${new_disk}2)

if [ -f "$fstab_path" ]; then
  # Replace root UUID
  sed -i "s/$old_root_uuid/$new_root_uuid/g" "$fstab_path"

  # Handle ESP
  if [ ! -z "$esp_part" ]; then
    if [ -z "$old_esp_uuid" ]; then old_esp_uuid=$(blkid -s UUID -o value $esp_part); fi
    sed -i "s/$old_esp_uuid/$new_esp_uuid/g" "$fstab_path"
  else
    if ! grep -q '/boot/efi' "$fstab_path"; then
      echo "Adding new /boot/efi entry to fstab."
      echo "UUID=$new_esp_uuid /boot/efi vfat defaults 0 2" >> "$fstab_path"
    else
      echo "/boot/efi already in fstab; no addition needed."
    fi
  fi

  # Remove separate /boot entry if merged
  if [ ! -z "$boot_part" ]; then
    echo "Removing separate /boot entry from fstab."
    #if [ ! -z "$old_boot_uuid" ]; then
      sed -i "/UUID=$old_boot_uuid/d" "$fstab_path"
    #elif [ ! -z "$old_boot_label" ]; then
      sed -i "/LABEL=$old_boot_label/d" "$fstab_path"
    #elif [[ "$boot_device" == /dev/* ]]; then
      boot_device_esc=$(echo "$boot_device" | sed 's/\//\\\//g')
      sed -i "/^$boot_device_esc[ \t]/d" "$fstab_path"
    #fi
  fi
else
  echo "fstab not found after cloning, creating a new one with root and ESP entries."
  mkdir -p /mnt/new/etc
  cat << EOF > "$fstab_path"
UUID=$new_root_uuid / ext4 defaults 0 1
UUID=$new_esp_uuid /boot/efi vfat defaults 0 2
EOF
fi

# Bind mounts for chroot
mount --bind /dev /mnt/new/dev
mount --bind /proc /mnt/new/proc
mount --bind /sys /mnt/new/sys
#mount --bind /run /mnt/new/run
mount --bind /dev/pts /mnt/new/dev/pts
modprobe efivarfs
mount --bind /sys/firmware/efi/efivars /mnt/new/sys/firmware/efi/efivars || true
mount --bind /etc/resolv.conf /mnt/new/etc/resolv.conf || cp -L /etc/resolv.conf /mnt/new/etc/resolv.conf

# copy autorun files
mkdir -p /mnt/new/opt/autorun
cp /opt/autorun/* /mnt/new/opt/autorun

# Install grub with UEFI support
chroot /mnt/new /bin/bash /opt/autorun/install_grub.sh "$new_disk"
rm /mnt/new/opt/autorun/install_grub.sh

# Install xrdp for Hyper-V Enhanced Session support
chroot /mnt/new /bin/bash /opt/autorun/install_xrdp.sh
rm /mnt/new/opt/autorun/install_xrdp.sh

# Remove Virtual Box additions
/opt/VBoxGuestAdditions-*/uninstall.sh || true #ignore failure

echo "autorun completed"
touch /run/autorun-done
exit 0
