# VM Customization Process

This document covers the customization pipeline inside the bootable ISO: how it reads host configuration, detects target disks, and applies customizations (Hyper-V guest daemons, xRDP) to turn a raw gallery image into a ready-to-use Hyper-V VM.

## Table of Contents

- [Design Overview](#design-overview)
- [Two Workflow Modes](#two-workflow-modes)
- [Host–Guest Signaling (KVP)](#hostguest-signaling-kvp)
- [KVP Corruption Mitigation](#kvp-corruption-mitigation)
- [Filesystem Support](#filesystem-support)
- [Hyper-V Guest Optimization](#hyper-v-guest-optimization)
- [xRDP / Enhanced Session Mode](#xrdp--enhanced-session-mode)
- [Remote Access (SSH & PowerShell Direct)](#remote-access-ssh--powershell-direct)
- [ISO Build Pipeline](#iso-build-pipeline)
- [Technologies](#technologies)

---

## Design Overview

Many Linux gallery images are distributed as pre-installed VHDX files (GPT-partitioned, Gen 2-ready) but ship without Hyper-V integration daemons or xRDP. Other images are legacy MBR/VHD files that need conversion to GPT before Hyper-V Gen 2 can boot them.

Both scenarios are handled by a **single bootable Ubuntu 24.04 ISO** (`hyperv-convert.iso`) that the host attaches to the VM. The ISO boots, reads configuration flags from the host via the Hyper-V KVP channel, executes the appropriate workflow, and powers the VM off cleanly via `OnSuccess=poweroff.target`. The host then detaches the ISO and boots the VM from its hard drive.

```
Hyper-V Host                                 ISO Guest
────────────                                 ─────────
Create VM (Gen 2)
Attach media + ISO
Start VM ───────────────────────────────────► systemd → autorun.service
Wait 10s
Send PADDING_1 ──► KVP VMBus ───────────────► .kvp_pool_0 (slot 1, corrupted)
Send PADDING_2 ──► KVP VMBus ───────────────► .kvp_pool_0 (slot 2, corrupted)
Send VMCREATE_MODE ► KVP VMBus ─────────────► .kvp_pool_0 (slot 3, clean)
Send VMCREATE_XRDP ► KVP VMBus ─────────────► .kvp_pool_0 (slot 4, clean)
                                               autorun.sh reads KVP
                                                 ├─ "customize" → customize_only.sh
                                                 └─ default     → clone workflow
                                               ...customization steps...
Poll guest KVP ◄── KVP VMBus ◄───────────────── report_progress() writes .kvp_pool_1
                                               exit 0
                                               systemd → poweroff.target
Wait for VM shutdown
Remove ISO
Set first boot to hard drive
```

---

## Two Workflow Modes

### Clone (Gen 1 / MBR images)

Used when the gallery image is MBR-partitioned. The host attaches **two** disks — the original MBR image and a new empty VHDX — plus the ISO. The ISO:

1. Detects which disk is empty (no partitions) and which has partitions.
2. Partitions the new disk as GPT with a 512 MB ESP + root.
3. Clones the root partition with `partclone` (real-time progress via KVP).
4. Clones or creates the ESP.
5. Merges a separate `/boot` partition into root (if present).
6. Updates `/etc/fstab` with new UUIDs.
7. Installs GRUB for UEFI boot.
8. Installs Hyper-V guest daemons + openssh-server.
9. Optionally installs xRDP.
10. Installs PowerShell for post-boot configuration.
11. Creates `vmcreate` automation user and injects SSH public key.
12. Writes ESP redirect grub.cfg for reliable UEFI boot.
13. Removes VirtualBox Guest Additions (many gallery images originate from VBox).
14. Cleans up autorun scripts from target.
15. Exits → systemd powers off the VM.

The host then detaches the original MBR disk and the ISO, leaving only the GPT disk.

### Customize-Only (Gen 2 / GPT images)

Used when the image is already GPT-partitioned. No second disk is needed. The ISO:

1. Finds the single partitioned `/dev/sd*` device.
2. Detects the root partition (checks for `/etc/fstab` + `/bin`).
3. Mounts root and ESP, sets up bind mounts for chroot.
4. Mounts additional fstab entries (e.g. `/home` on separate partition/subvolume).
5. Installs Hyper-V guest daemons + openssh-server.
6. Optionally installs xRDP.
7. Installs PowerShell for post-boot configuration.
8. Creates `vmcreate` automation user and injects SSH public key.
9. Cleans up autorun scripts from target.
10. Exits → systemd powers off the VM.

The host decides which workflow to trigger by sending `VMCREATE_MODE=customize` via KVP for Gen 2 images, or omitting it (defaulting to clone) for Gen 1.

---

## Host–Guest Signaling (KVP)

### Mechanism

Hyper-V Key-Value Pair (KVP) exchange uses VMBus to pass data between host and guest without a network connection. Each record is a fixed **2560 bytes** (512-byte key + 2048-byte value), stored in pool files under `/var/lib/hyperv/`.

| Direction | Pool File | Used For |
|-----------|-----------|----------|
| Host → Guest | `.kvp_pool_0` | Configuration flags (`VMCREATE_MODE`, `VMCREATE_XRDP`, `VMCREATE_XRDP_USERNAME`, `VMCREATE_SSH_PUBKEY`, `VMCREATE_DEBUG`) |
| Guest → Host | `.kvp_pool_1` | Progress reporting (`WorkflowProgress`, `PartcloneProgress`) |

### Host Side (C# / WMI)

The `KvpHostToGuest` class uses WMI `Msvm_VirtualSystemManagementService.AddKvpItems` to push key-value pairs. It includes retry logic (5 attempts, 5 s delay) and waits for WMI job completion.

### Guest Side (Bash)

`lib/functions.sh` provides `send_kvp`, `read_kvp`, and `read_kvp_value`:

- **`send_kvp(key, value)`** — Writes a 2560-byte record to `.kvp_pool_1` (guest-to-host).
- **`read_kvp(pool)`** — Iterates all records with `dd`, prints key-value pairs.
- **`read_kvp_value(pool, key)`** — Returns the value for a specific key.

### Wait Loop

`autorun.sh` polls for `VMCREATE_MODE` for up to **30 seconds** because the host doesn't send KVP until 10 s after VM start, and `hv_kvp_daemon` may take additional time to flush the pool file.

```bash
for i in $(seq 1 30); do
    VMCREATE_MODE=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_MODE")
    [ -n "$VMCREATE_MODE" ] && break
    sleep 1
done
```

---

## KVP Corruption Mitigation

### The Problem

When a Gen 2 VM boots, Hyper-V pushes network configuration (IP addresses, DNS servers, IPv6 multicast prefixes) through the **same VMBus KVP channel** that `AddKvpItems` uses. Both data streams land in `.kvp_pool_0` as fixed-size records.

If the WMI writes overlap with the network configuration burst, records get corrupted. In practice, the **first two records** written via `AddKvpItems` are consistently mangled — for example, `DUMMY` becomes `DUMMYcastprefix` with `ff02::` multicast data in the value field.

This is **not** purely a timing issue. Even with a 10 s delay between VM start and the first WMI write, the first two record slots are still corrupted. The root cause is that `hv_kvp_daemon` is often inactive and the kernel's `hv_utils` module doesn't properly serialize VMBus writes across pools.

### The Fix

A two-layer mitigation ensures reliable KVP delivery:

**Layer 1 — Host side (C#):** Wait 10 s for boot to settle, then send two **throwaway padding KVPs** before any real configuration keys:

```csharp
await Task.Delay(TimeSpan.FromSeconds(10), ct);
await kvp.SendKVPToGuestAsync(vmName, "PADDING_1", "true", ct);
await kvp.SendKVPToGuestAsync(vmName, "PADDING_2", "true", ct);
// Real keys land in slot 3+ where corruption doesn't reach
await kvp.SendKVPToGuestAsync(vmName, "VMCREATE_MODE", "customize", ct);
await kvp.SendKVPToGuestAsync(vmName, "VMCREATE_XRDP", "true", ct);
```

**Layer 2 — Guest side (Bash):** The 30 s retry loop acts as belt-and-suspenders — if the first read attempt catches corrupted data, subsequent attempts may succeed after the daemon re-processes the pool.

---

## Filesystem Support

The customization scripts must detect the root partition on arbitrary Linux distributions. Root detection uses `blkid` to read the filesystem type, then validates the partition contains `/etc/fstab` and `/bin`.

Supported filesystem types:

| Filesystem | Distributions |
|-----------|---------------|
| ext2/3/4 | Ubuntu, Debian, Fedora, RHEL, most distributions |
| btrfs | Parrot Security OS, openSUSE |
| xfs | CentOS, RHEL (default since RHEL 7) |

```bash
# customize_only.sh & functions.sh — root detection regex
if [[ "$fs_type" =~ ^(ext[234]|btrfs|xfs)$ ]]; then
    # mount and check for fstab + /bin
fi
```

The ISO includes `btrfs-progs` (installed in `chroot_setup.sh`) so btrfs volumes can be mounted during customization.

---

## Hyper-V Guest Optimization

Both workflows install integration daemons that make the guest a first-class Hyper-V citizen. This step runs via `chroot` into the target guest OS (not the ISO), so the daemons persist after the ISO is detached.

### Installed Components

| Daemon | Purpose |
|--------|---------|
| `hv_kvp_daemon` | Host↔guest key-value pair exchange (enables data exchange service) |
| `hv_vss_daemon` | Volume Shadow Copy integration (enables live checkpoints) |
| `hv_fcopy_daemon` | Host-to-guest file copy service |
| `openssh-server` | Enables PowerShell Direct (SSH over VMBus/hv_sock) |

### Multi-Distro Package Manager Support

The installation detects the available package manager and adapts:

```bash
if command -v apt-get >/dev/null 2>&1; then         # Debian/Ubuntu/Parrot/Kali
    # Try Ubuntu packages first, fall back to Debian's hyperv-daemons
    if apt-get install -y -qq linux-cloud-tools-common; then
        apt-get install -y -qq "linux-cloud-tools-${KVER}" || true
    elif apt-get install -y -qq hyperv-daemons; then
        echo 'Installed hyperv-daemons (Debian/Parrot)'
    fi
    apt-get install -y -qq openssh-server
elif command -v dnf >/dev/null 2>&1; then            # Fedora
    dnf install -y -q hyperv-daemons openssh-server
elif command -v yum >/dev/null 2>&1; then            # RHEL/CentOS
    yum install -y -q hyperv-daemons openssh-server
elif command -v pacman >/dev/null 2>&1; then          # Arch
    pacman -Sy --noconfirm hyperv openssh sudo
fi
```

### Non-Fatal Design

The optimization step is **non-fatal** — if the guest's package manager fails (e.g., expired repository keys, missing packages), the VM still boots correctly. The error is logged and reported via KVP as a warning but does not abort the workflow.

---

## xRDP / Enhanced Session Mode

When the user enables xRDP in the VMCreate GUI, the `VMCREATE_XRDP=true` flag is sent via KVP. The customization scripts install and configure xRDP inside the target guest via chroot.

### How It Works

`install_xrdp.sh` detects the guest distribution using `/etc/os-release` and installs xRDP with the appropriate package manager (apt, dnf, pacman, zypper).

### vsock Transport

xRDP is configured to use the **Hyper-V VMBus socket** transport instead of TCP, which enables Enhanced Session Mode without network configuration:

```ini
; /etc/xrdp/xrdp.ini
port=vsock://-1:3389
security_layer=rdp
crypt_level=none
```

This means the RDP connection travels over VMBus (AF_VSOCK) rather than the virtual network adapter, providing:
- Lower latency than TCP
- No firewall rules needed
- Works even if the VM has no network connectivity

### Supported Distributions

| Family | Detection | Package Manager |
|--------|-----------|-----------------|
| Arch | `$ID = "arch"` or `$ID_LIKE =~ arch` | `pacman` |
| Debian | `$ID ∈ {debian, ubuntu}` or `$ID_LIKE =~ debian` | `apt-get` |
| Fedora | `$ID = "fedora"` or `$ID_LIKE =~ fedora` | `dnf` |
| openSUSE | `$ID ∈ {opensuse-tumbleweed, opensuse-leap}` or `$ID_LIKE =~ suse` | `zypper` |

---

## Remote Access (SSH & PowerShell Direct)

The ISO provides two mechanisms for the Hyper-V host to run commands inside the guest: **network SSH** (plink/ssh) and **PowerShell Direct** (Invoke-Command over VMBus). The ISO guest uses `ubuntu/ubuntu` credentials. The **target VM** (after conversion) uses a `vmcreate` automation user with SSH key-based authentication — the public key is injected during conversion via the `VMCREATE_SSH_PUBKEY` KVP.

### How SSH over VMBus Works

Hyper-V exposes a **VMBus socket** (AF_VSOCK / `hv_sock`) between host and guest. When the guest has `openssh-server` running, the host can establish an SSH connection through this channel — no virtual network adapter required.

```
┌──────────────────────┐         VMBus (hv_sock)         ┌─────────────────────┐
│  Hyper-V Host        │◄═══════════════════════════════►│  ISO Guest          │
│                      │         AF_VSOCK socket          │                     │
│  Invoke-Command      │───► SSH client ──► VMBus ──────►│  sshd ──► pwsh      │
│  -VMName "MyVM"      │                                  │    (SSH subsystem)  │
│  -Credential $cred   │                                  │                     │
│  -ScriptBlock {...}  │◄─── stdout ◄──── VMBus ◄───────│  command output      │
└──────────────────────┘                                  └─────────────────────┘
```

Under the hood:
1. PowerShell uses `hv_sock` to reach the guest's SSH port without traversing the network stack
2. SSH authenticates with password credentials
3. The `Subsystem powershell` directive in `sshd_config` launches `pwsh -sshs` as the remoting endpoint
4. PowerShell serializes objects over the SSH channel (PSRP over SSH)

### Guest Requirements

The ISO's `chroot_setup.sh` installs everything needed:

| Component | Package | Purpose |
|-----------|---------|---------|
| SSH server | `openssh-server` | Listens for SSH connections (network + VMBus) |
| Password auth | `sshd_config` edit | Allows `ubuntu/ubuntu` credential login |
| VMBus kernel module | `hv_sock` (built into `linux-azure`) | VMBus socket transport |

PowerShell (`pwsh`) is **not** installed in the ISO itself — it is installed on the **target VM** during conversion via `install_pwsh.sh`, enabling PowerShell Direct for post-boot configuration.

### Network SSH (plink)

When the VM has a network adapter, standard SSH works over the virtual network. This is useful for interactive debugging from a Windows terminal using PuTTY's `plink`:

```powershell
# Get the VM's IP address
$vmName = "MyVM_20260307230223"
(Get-VMNetworkAdapter -VMName $vmName).IPAddresses

# SSH via plink with password (non-interactive)
plink -ssh ubuntu@172.24.137.116 -pw ubuntu `
    -hostkey "SHA256:CCR5H4+3iMmzXa/9JMZb4loOLpYvpq0BcjS2+vxakQ4" `
    "hostname; systemctl status autorun.service 2>&1"

# First connection: accept host key
# plink will print the fingerprint — use -hostkey to pin it on subsequent calls

# Useful diagnostic commands
plink -ssh ubuntu@172.24.137.116 -pw ubuntu -hostkey "SHA256:..." `
    "journalctl -u autorun.service --no-pager -n 50 2>&1"

plink -ssh ubuntu@172.24.137.116 -pw ubuntu -hostkey "SHA256:..." `
    "systemctl show autorun.service -p ExecMainStatus -p Result -p ActiveState"

plink -ssh ubuntu@172.24.137.116 -pw ubuntu -hostkey "SHA256:..." `
    "cat /var/lib/hyperv/.kvp_pool_0 | strings"
```

> **Note:** The first plink connection requires accepting the host key. Pipe `echo y |` or use `-hostkey` with the fingerprint. The `ssh` command with `-o StrictHostKeyChecking=no` also works but requires `sshpass` for non-interactive password auth on Windows.

### PowerShell Direct (Invoke-Command)

PowerShell Direct is the preferred programmatic access method — it works over VMBus without any network dependency. This is what the VMCreate GUI uses.

```powershell
# Create credentials
$cred = New-Object PSCredential("ubuntu", (ConvertTo-SecureString "ubuntu" -AsPlainText -Force))

# Run a command in the ISO guest
$result = Invoke-Command -VMName "MyVM_20260307230223" -Credential $cred -ScriptBlock {
    hostname
    systemctl status autorun.service 2>&1 | Out-String
    journalctl -u autorun.service --no-pager -n 50 2>&1 | Out-String
}

# Interactive session
Enter-PSSession -VMName "MyVM_20260307230223" -Credential $cred

# Copy a file from the guest to the host
$s = New-PSSession -VMName "MyVM_20260307230223" -Credential $cred
Copy-Item -FromSession $s -Path "/var/log/autorun.log" -Destination "C:\temp\"
Remove-PSSession $s
```

**Key difference from network SSH:** PowerShell Direct requires `pwsh` installed on the guest with the SSH subsystem configured. The conversion scripts install this on the **target VM** via `install_pwsh.sh`. Without `pwsh`, the SSH connection succeeds but PS remoting fails with:
```
OpenError: An error has occurred which PowerShell cannot handle.
A remote session might have ended.
```

### Limitation

Both access methods only work with the **ISO guest** (which has openssh-server built in) or the **converted target VM** (which gets openssh-server + pwsh installed during conversion). Stock images like Parrot Security OS lack `hv_sock` and SSH entirely — `Invoke-Command` hangs indefinitely. This is why the ISO-based chroot approach is the only reliable customization method.

### Test Script

`test/test_autorun_vm.ps1` provides three modes for debugging:

```powershell
# Dump journal + system context
.\test_autorun_vm.ps1

# Stream journal in real-time until VM shuts down
.\test_autorun_vm.ps1 -Follow

# Run an arbitrary command
.\test_autorun_vm.ps1 -Command "cat /var/lib/hyperv/.kvp_pool_0 | strings"
```

Uses `ubuntu/ubuntu` credentials, waits up to 120 s for SSH readiness.

---

## ISO Build Pipeline

### Overview

`build.sh` creates the ISO from scratch using `debootstrap`:

1. **Bootstrap** — `debootstrap --arch=amd64 --variant=minbase noble` creates a minimal Ubuntu 24.04 chroot.
2. **Copy scripts** — `autorun/*.sh` → `chroot/opt/autorun/`, `lib/functions.sh` → `chroot/opt/lib/`.
3. **Configure chroot** — Runs `chroot_setup.sh` which installs the kernel (`linux-azure`), disk tools, SSH, and sets up `autorun.service`.
4. **Create squashfs** — `mksquashfs chroot/ image/casper/filesystem.squashfs -comp xz -b 1M -Xbcj x86`.
5. **Generate ISO** — `xorriso` creates a UEFI-only ISO (no BIOS/legacy boot).

### Key Packages in the ISO

| Package | Purpose |
|---------|---------|
| `linux-azure` | Hyper-V optimized kernel with hv_* modules |
| `partclone` | Block-level partition cloning |
| `gdisk` / `sgdisk` | GPT partition table manipulation |
| `btrfs-progs` | btrfs filesystem tools |
| `openssh-server` | Network SSH support in the ISO |
| `sed` | Strip ANSI escape codes from partclone output |
| `grub-efi-amd64-signed` | Secure Boot compatible GRUB |
| `shim-signed` | Secure Boot shim loader |

### NTFS Guard

`build.sh` refuses to run on NTFS-mounted filesystems (e.g., `/mnt/c` in WSL) because `debootstrap` requires Unix symlinks and device nodes. This prevents a common gotcha.

---

## Technologies

| Technology | Role |
|------------|------|
| **Hyper-V KVP (Key-Value Pair) Exchange** | Host↔guest communication over VMBus without network |
| **VMBus** | High-speed Hyper-V paravirtualized bus for I/O, KVP, and vsock |
| **Ubuntu 24.04 LTS (Noble)** | ISO base operating system (debootstrapped) |
| **debootstrap** | Builds minimal Ubuntu chroot from scratch |
| **systemd** | ISO service management — `autorun.service` with `OnSuccess=poweroff.target` |
| **partclone** | Block-level partition cloning with progress reporting |
| **sgdisk** | GPT partition table manipulation |
| **GRUB 2 (EFI)** | Bootloader installation in cloned systems |
| **xRDP** | RDP server for Hyper-V Enhanced Session Mode (vsock transport) |
| **AF_VSOCK / hv_sock** | VMBus socket transport for xRDP and PowerShell Direct |
| **openssh-server** | SSH server for network access and VMBus transport |
| **PowerShell (pwsh)** | Installed on target VM for post-boot PowerShell Direct remoting |
| **squashfs** | Read-only compressed filesystem for the live ISO (XZ + x86 BCJ) |
| **xorriso** | ISO 9660 / El Torito image creation (UEFI-only) |
| **Bash** | All ISO-side automation scripts |

---

## Design Decisions

### Why a bootable ISO instead of PowerShell Direct?

PowerShell Direct (SSH over VMBus) only works when the guest already has `openssh-server`, `pwsh`, and `hv_sock` loaded. Stock gallery images (Parrot, Kali, etc.) don't ship with these — `Invoke-Command` hangs indefinitely. The ISO provides a known-good environment that can reach into any guest via chroot. The ISO's own PowerShell Direct support is used for **monitoring and error collection**, not for driving the customization itself.

### Why padding KVPs instead of longer delays?

The KVP corruption is **not** timing-dependent — the first two record slots are consistently corrupted regardless of delay duration. Adding dummy records is the only reliable mitigation because it pushes real data past the corruption zone.

### Why chroot instead of direct installation?

The ISO cannot `apt-get install` packages into a powered-off VHDX. By booting the ISO alongside the target disk, mounting the target's root, and running `chroot /mnt/new /bin/bash`, the customization scripts execute in the target's own environment — using its package manager, repositories, and configuration. This works across all supported distributions.

### Why non-fatal optimization steps?

Distribution images vary widely — some have expired GPG keys, missing repositories, or custom package managers. Making `hyperv-daemons` and `openssh-server` installation non-fatal ensures the VM always boots, even if optimization partially fails. The user gets a warning but not a broken VM.

### Why vsock transport for xRDP?

The `vsock://-1:3389` transport routes RDP traffic through VMBus instead of TCP. This enables Enhanced Session Mode without firewall rules, network configuration, or even a virtual network adapter. It's faster, more secure, and works in air-gapped scenarios.

### Why `linux-azure` kernel?

The `linux-azure` kernel includes Hyper-V paravirtualized drivers (`hv_vmbus`, `hv_storvsc`, `hv_netvsc`, `hv_utils`, `hv_sock`) compiled in rather than as modules, ensuring maximum compatibility and performance when the ISO boots in Hyper-V.
