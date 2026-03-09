# hyperv-convert-iso

A bootable ISO that automatically clones Linux disks in Hyper-V environments. Boot the ISO with source and target disks attached, and it handles the rest—detection, cloning, configuration, and shutdown.

## Quick Start

```bash
# Build the ISO
sudo ./script.sh

# Output: hyperv-convert.iso (~500MB)
```

**Requirements:**
- Hyper-V Gen2 VM with Data Exchange enabled
- 2GB RAM minimum
- Two disks: source (Linux) and target (empty, ≥ source used space)

## How It Works

1. Boot ISO in Hyper-V VM
2. Auto-detects source and target disks
3. Clones partitions with progress reporting via KVP
4. Configures bootloader and optionally installs XRDP
5. Shuts down automatically

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed workflow and system design.

## Configuration

Control behavior via Hyper-V KVP (VMCreate GUI sets these automatically):

| Flag | Values | Description |
|------|--------|-------------|
| `VMCREATE_XRDP` | `true`/`false` | Install XRDP for Enhanced Session |
| `VMCREATE_DEBUG` | `true`/`false` | Enable verbose logging |

## Testing

```bash
# Lint
shellcheck autorun/*.sh lib/*.sh script.sh chroot_setup.sh

# Test
bats test/
```

**Test Coverage:** 19 BATS tests covering disk detection, fstab updates, KVP communication, and core utilities.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Disk too small** | Ensure target ≥ source used space |
| **Shutdown hang** | Check `journalctl -u autorun.service` |
| **No progress updates** | Verify Hyper-V Data Exchange is enabled |
| **Clone failures** | Run `e2fsck -f` on source disk before conversion |

**Debug Mode:** Set `VMCREATE_DEBUG=true` for verbose logging.

**Logs:**
- `/var/log/hyperv-convert.log` - Main log
- `journalctl -u autorun.service` - Service logs

## Architecture

```
ISO Boot → Systemd autorun.service → autorun.sh workflow:
  1. Pre-flight checks (disk size, tools, KVP)
  2. Disk detection and partitioning
  3. Partition cloning (partclone with progress)
  4. Filesystem verification (fsck)
  5. fstab updates and GRUB installation
  6. Optional XRDP installation
  7. Cleanup and shutdown
```

**Key Files:**
- `autorun/autorun.sh` - Main conversion script
- `lib/functions.sh` - Shared utilities (KVP, logging, disk ops)
- `test/` - BATS test suite

For complete technical details, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Development

**Contributing:**
1. Run ShellCheck before committing
2. Add tests for new functionality
3. Ensure CI passes (lint → test → build)

**CI Pipeline:** GitHub Actions runs ShellCheck, BATS tests, and ISO build on every push.

## License

[Add license information]

## Support

- **ISO issues:** Open an issue in this repository
- **VMCreate GUI:** Contact VMCreate maintainers
- **Hyper-V setup:** See Microsoft Hyper-V documentation