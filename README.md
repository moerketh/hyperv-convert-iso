# hyperv-convert-iso

> **Note:** This ISO is not intended to be used standalone. It is designed to work with [VMCreate](https://github.com/moerketh/VMCreate), which orchestrates the VM lifecycle and sends the required parameters via Hyper-V KVP.

A bootable ISO that clones and converts Linux disks inside Hyper-V VMs. It handles disk detection, partclone cloning, GRUB installation, and optional customizations (xRDP, PowerShell, SSH), then shuts down automatically.

## Building

```bash
sudo ./build.sh
# Output: hyperv-convert.iso
```

## How It Works

1. VMCreate boots the ISO in a Hyper-V Gen2 VM with source and target disks attached
2. Autorun detects disks, clones partitions (with progress via KVP), and installs GRUB
3. Optionally installs xRDP, PowerShell, and sets up SSH for post-boot management
4. Shuts down — VMCreate then boots the VM from the converted disk

Two modes are supported:
- **Clone** (Gen1 MBR → GPT): Clones the source disk to a new GPT disk with UEFI boot
- **Customize-only** (Gen2 GPT): Skips cloning, applies customizations to an existing disk

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full workflow.

## Security & Privacy Notice

This ISO modifies network configuration, firewall rules, SSH settings, and boot infrastructure inside the target VM to make it compatible with Hyper-V. VMCreate does its best to restore distribution defaults after customization completes.

**If you depend on the security or privacy features of a distribution (e.g. Whonix, Tails), do not use this toolchain to deploy it.** The modifications may weaken or bypass the protections those distributions are designed to provide.

Many of these distributions were not designed or tested by their creators to run in Hyper-V. Running them in this way may void any warranty or support provided by the distribution maintainers.

## KVP Parameters

Set automatically by VMCreate:

| Flag | Description |
|------|-------------|
| `VMCREATE_MODE` | `customize` for Gen2, absent for clone |
| `VMCREATE_XRDP` | `true` to install xRDP |
| `VMCREATE_SSH_PUBKEY` | SSH public key for automation user |
| `VMCREATE_DEBUG` | `true` to keep VM running after completion |

## Testing

```bash
shellcheck autorun/*.sh lib/*.sh build.sh chroot_setup.sh
bats test/
```

## Key Files

| File | Purpose |
|------|---------|
| `build.sh` | Builds the ISO from a debootstrap chroot |
| `autorun/autorun.sh` | Main clone workflow |
| `autorun/customize_only.sh` | Customize-only workflow (Gen2) |
| `lib/functions.sh` | Shared utilities (KVP, disk ops, networking) |
| `autorun/install_xrdp.sh` | xRDP installation and configuration |
| `autorun/install_grub.sh` | GRUB bootloader installation |
| `autorun/install_pwsh.sh` | PowerShell installation |

## Troubleshooting

- **No progress updates** — Verify Hyper-V Data Exchange integration service is enabled
- **Shutdown hang** — Check `journalctl -u autorun.service` inside the VM
- **Debug mode** — Set `VMCREATE_DEBUG=true` to keep the VM running for inspection