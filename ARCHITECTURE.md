# Architecture Documentation

## System Overview

The hyperv-convert-iso is a bootable Ubuntu-based live environment that automatically converts Linux virtual machines in Hyper-V environments. The system operates as a single-use conversion tool that boots from ISO, detects source and target disks, clones partitions with progress reporting, and shuts down upon completion.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Hyper-V Host Environment                    │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │ VMCreate    │    │ KVP Service │    │ Hyper-V VM          │  │
│  │ GUI         │◄──►│ Data        │◄──►│ ┌─────────────────┐ │  │
│  │             │    │ Exchange    │    │ │ hyperv-convert  │ │  │
│  │             │    │             │    │ │ ISO             │ │  │
│  │             │    │             │    │ │ (Live Ubuntu)   │ │  │
│  │             │    │             │    │ └─────────────────┘ │  │
│  └─────────────┘    └─────────────┘    │ ┌─────────────────┐ │  │
│                                       │ │ Source Disk    │ │  │
│                                       │ │ (Linux)        │ │  │
│                                       │ └─────────────────┘ │  │
│                                       │ ┌─────────────────┐ │  │
│                                       │ │ Target Disk    │ │  │
│                                       │ │ (Empty)        │ │  │
│                                       │ └─────────────────┘ │  │
│                                       └─────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Boot Flow

The system follows a deterministic boot sequence from ISO initialization to clean shutdown:

```
1. ISO Boot (UEFI)
   ↓
2. GRUB Loader
   ├─ Loads kernel (vmlinuz)
   ├─ Loads initramfs
   └─ Boots Ubuntu Live environment
   ↓
3. Systemd Initialization
   ├─ Mounts filesystems
   ├─ Starts services
   └─ Triggers autorun.service
   ↓
4. autorun.service Execution
   ├─ Source: /opt/autorun/autorun.sh
   ├─ Type: oneshot
   └─ OnSuccess: poweroff.target
   ↓
5. Main Conversion Workflow (autorun.sh)
   ├─ Source functions.sh library
   ├─ Set cleanup trap (mounts, autorun-done flag)
   ├─ Detect disks (empty target, partitioned source)
   ├─ Pre-flight validation
   ├─ Partition target disk (GPT layout)
   ├─ Clone partitions with partclone
   ├─ Verify filesystems
   ├─ Mount new system
   ├─ Update fstab (UUID replacement)
   ├─ Install GRUB bootloader
   ├─ Install XRDP (optional)
   ├─ Cleanup VirtualBox additions
   └─ Exit with status 0
   ↓
6. Systemd Completion
   ├─ autorun.service exits successfully
   ├─ OnSuccess=poweroff.target triggers
   ├─ Clean system shutdown
   └─ VM powers off
```

## Component Descriptions

### Core Scripts

#### script.sh (ISO Builder)
- **Purpose**: Creates bootable ISO from Ubuntu minimal base
- **Size**: 179 lines
- **Key Operations**:
  - Bootstrap Ubuntu 24.04 LTS chroot with debootstrap
  - Install minimal packages for live environment
  - Configure autorun.service for automatic execution
  - Generate squashfs filesystem
  - Create hybrid ISO with BIOS/UEFI/Secure Boot support
- **Output**: `hyperv-convert.iso` (~500MB)

#### chroot_setup.sh (Live Environment Setup)
- **Purpose**: Configures the live environment inside the ISO
- **Size**: 108 lines
- **Key Operations**:
  - Install kernel, systemd, and required utilities
  - Configure systemd-networkd for DHCP
  - Setup autorun.service with OnSuccess=poweroff.target
  - Override getty@tty1 to wait for /run/autorun-done
  - Create ubuntu user for debugging
  - Package cleanup for minimal footprint

#### autorun/autorun.sh (Main Conversion Logic)
- **Purpose**: Executes the complete disk conversion workflow
- **Size**: 158 lines
- **Key Operations**:
  - Disk detection and partition analysis
  - Target disk partitioning (GPT with ESP + root)
  - Partition cloning with real-time progress reporting
  - Filesystem verification
  - Mount management and chroot preparation
  - GRUB and XRDP installation orchestration
  - Cleanup and shutdown coordination

#### lib/functions.sh (Shared Utilities)
- **Purpose**: Provides reusable functions for all system components
- **Size**: 513 lines
- **Key Functions**:
  - KVP communication (send_kvp, read_kvp)
  - Progress reporting and logging
  - Retry mechanisms for transient failures
  - Pre-flight validation
  - Disk detection and partition analysis
  - Filesystem verification
  - fstab updating with UUID replacement
  - Mount/unmount coordination

### Specialized Scripts

#### autorun/install_grub.sh (GRUB Bootloader)
- **Purpose**: Installs GRUB in target system chroot
- **Operations**:
  - UEFI GRUB installation to ESP
  - GRUB configuration generation
  - Boot entry creation

#### autorun/install_xrdp.sh (Enhanced Session)
- **Purpose**: Installs XRDP for RDP-based Enhanced Session Mode
- **Operations**:
  - Package installation (xrdp, desktop environment)
  - Service configuration
  - User session setup

### System Configuration

#### autorun.service
```ini
[Unit]
Description=Run autorun script on boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "/opt/autorun/autorun.sh"
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=no
OnSuccess=poweroff.target

[Install]
WantedBy=multi-user.target
```

#### getty@tty1 Override
```ini
[Service]
ExecStartPre=-/bin/sh -c 'while [ ! -f /run/autorun-done ]; do sleep 1; done'
TTYReset=no
TTYVHangup=no
```

## KVP Protocol Specification

The Hyper-V Data Exchange (KVP) service enables bidirectional communication between the VM and host system.

### Pool Files
- **Host-to-Guest**: `/var/lib/hyperv/.kvp_pool_0` (read by guest)
- **Guest-to-Host**: `/var/lib/hyperv/.kvp_pool_1` (written by guest)

### Record Format
Each KVP record consists of:
```
Key: 512 bytes (null-terminated, null-padded)
Value: 2048 bytes (null-terminated, null-padded)
Total: 2560 bytes per record
```

### Communication Keys

#### Guest-to-Host (Progress Reporting)
| Key | Purpose | Value Format | Example |
|-----|---------|--------------|---------|
| `WorkflowProgress` | Current workflow step | "STEP: description" | "PREFLIGHT: Disk detection complete" |
| `PartcloneProgress` | Cloning progress details | "Completed: 100% | Done" | "Progress: 45% | Rate: 2.3 GB/min" |
| `PreflightError` | Pre-flight error details | Error description | "New disk too small: 10737418240 < 21474836480 bytes" |
| `PreflightWarning` | Pre-flight warnings | Warning description | "KVP directory missing" |

#### Host-to-Guest (Configuration)
| Key | Purpose | Value Format | Example |
|-----|---------|--------------|---------|
| `VMCREATE_XRDP` | XRDP installation flag | "true"/"false" | "true" |
| `VMCREATE_DEBUG` | Debug mode flag | "true"/"false" | "false" |

### Implementation Details

#### send_kvp Function
```bash
send_kvp() {
    local key="$1"
    local value="$2"
    local pool="/var/lib/hyperv/.kvp_pool_1"
    local tmpfile=$(mktemp)
    
    # Write null-terminated key (512 bytes)
    printf "%s\0" "$key" > "$tmpfile"
    truncate -s 512 "$tmpfile"
    
    # Append null-terminated value (2048 bytes)
    printf "%s\0" "$value" >> "$tmpfile"
    truncate -s 2560 "$tmpfile"
    
    # Append to pool
    cat "$tmpfile" >> "$pool"
    rm "$tmpfile"
}
```

#### read_kvp Function
```bash
read_kvp() {
    local pool_file="${1:-/var/lib/hyperv/.kvp_pool_0}"
    local key_size=512
    local value_size=2048
    local kvp_index=0
    
    while true; do
        kvp_start_byte=$((kvp_index * (key_size + value_size)))
        kvp_key_offset=$kvp_start_byte
        kvp_value_offset=$((kvp_start_byte + key_size))
        
        kvp_key=$(dd status=none if="$pool_file" bs=1 skip="$kvp_key_offset" count="$key_size" 2>/dev/null | tr -d '\0')
        kvp_value=$(dd status=none if="$pool_file" bs=1 skip="$kvp_value_offset" count="$value_size" 2>/dev/null | tr -d '\0')
        
        [ -z "$kvp_key" ] && break
        echo "Key: $kvp_key Value: $kvp_value"
        kvp_index=$((kvp_index + 1))
    done
}
```

## Disk Layout

### Source Disk Structure
```
/dev/sdX (Source Linux Installation)
├─ /dev/sdX1: ESP (vfat, ~512MB) [Optional - may be separate]
├─ /dev/sdX2: /boot (ext4, ~1GB) [Optional - separate boot]
└─ /dev/sdX3: root (ext4, remaining space)
```

### Target Disk Structure (After Conversion)
```
/dev/sdY (Target Disk)
├─ /dev/sdY1: ESP (vfat, 512MB)
└─ /dev/sdY2: root (ext4, remaining space, includes merged /boot)
```

### Partition Creation Commands
```bash
# Create GPT partition table
sgdisk --zap-all $new_disk

# Create ESP partition (512MB, EFI System Partition type)
sgdisk --new=1:2048:+512M --typecode=1:ef00 --change-name=1:ESP $new_disk

# Create root partition (rest of disk, Linux filesystem type)
sgdisk --new=2::0 --typecode=2:8300 --change-name=2:root $new_disk

# Format partitions
mkfs.vfat -F32 ${new_disk}1
mkfs.ext4 ${new_disk}2
```

### fstab Transformation
The conversion process updates `/etc/fstab` to use new partition UUIDs:

```bash
# Before (source system)
UUID=old-root-uuid / ext4 defaults 0 1
UUID=old-esp-uuid /boot/efi vfat defaults 0 2
UUID=old-boot-uuid /boot ext4 defaults 0 2

# After (converted system)
UUID=new-root-uuid / ext4 defaults 0 1
UUID=new-esp-uuid /boot/efi vfat defaults 0 2
# /boot entry removed (merged into root)
```

## Error Handling

### Pre-flight Validation
The system performs comprehensive pre-flight checks before disk operations:

1. **Disk Size Validation**
   - Target disk size >= Source disk used space
   - Error: "New disk is smaller than old disk used space"
   - KVP: `PreflightError: New disk too small: {bytes}`

2. **Required Tools Verification**
   - All essential tools must be available (partclone, sgdisk, etc.)
   - Error: "Missing required tools: {list}"
   - KVP: `PreflightError: Missing tools: {list}`

3. **KVP Service Accessibility**
   - Pool files must exist and be writable
   - Warning: "KVP directory missing" or "KVP pool 0 missing"
   - KVP: `PreflightWarning: {description}`

### Runtime Error Handling
- **Set -e**: Script exits on any command failure
- **Trap Cleanup**: Ensures proper unmounting on script exit/failure
- **Retry Mechanism**: Transient failures retried with exponential backoff
- **Progress Reporting**: Errors communicated via KVP to host

### Cleanup Procedures
The `cleanup_mounts` function ensures proper resource cleanup:

```bash
cleanup_mounts() {
    # Unmount in REVERSE order (LIFO)
    umount -lf /mnt/new/etc/resolv.conf 2>/dev/null || true
    umount -lf /mnt/new/sys/firmware/efi/efivars 2>/dev/null || true
    umount -lf /mnt/new/dev/pts 2>/dev/null || true
    umount -lf /mnt/new/sys 2>/dev/null || true
    umount -lf /mnt/new/proc 2>/dev/null || true
    umount -lf /mnt/new/dev 2>/dev/null || true
    umount -lf /mnt/new/boot/efi 2>/dev/null || true
    umount -lf /mnt/new 2>/dev/null || true
    
    # Signal completion to getty override
    touch /run/autorun-done
}
```

### Filesystem Verification
Post-cloning verification ensures data integrity:

- **Root Partition**: e2fsck -n (read-only check)
- **ESP Partition**: fsck.vfat -n (read-only check)
- **Failure Mode**: Verification errors cause script abort with KVP error reporting

### Logging Strategy
- **Main Log**: `/var/log/hyperv-convert.log` (timestamped entries)
- **Partclone Log**: `/tmp/partclone.log` (detailed cloning output)
- **Progress Log**: `/tmp/partclone_process.log` (real-time progress parsing)
- **Systemd Journal**: `journalctl -u autorun.service` (service-level events)

This architecture ensures reliable, automated disk conversion with comprehensive error detection, progress reporting, and clean resource management.