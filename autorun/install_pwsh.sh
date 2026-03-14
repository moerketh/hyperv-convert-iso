#!/bin/bash
set -e

# Multi-distro PowerShell (pwsh) installer for target VMs.
# Runs inside chroot of the target VM's filesystem.
# Required for post-boot PowerShell Direct (Invoke-Command -VMName).
# Pattern mirrors install_xrdp.sh — detect distro family, install, configure SSH subsystem.

# Source os-release to get $ID, $ID_LIKE
. /etc/os-release

# Determine the package manager family
is_arch() { [ "$ID" = "arch" ] || [[ "${ID_LIKE:-}" =~ arch ]]; }
is_debian() { [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ] || [[ "${ID_LIKE:-}" =~ debian ]]; }
is_fedora() { [ "$ID" = "fedora" ] || [[ "${ID_LIKE:-}" =~ fedora ]]; }
is_suse() { [ "$ID" = "opensuse-tumbleweed" ] || [ "$ID" = "opensuse-leap" ] || [[ "${ID_LIKE:-}" =~ suse ]]; }

###############################################################################
# Install PowerShell
###############################################################################
if is_debian; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -qq
    apt-get install -y -qq wget apt-transport-https 2>&1

    # Determine the Ubuntu/Debian version for the Microsoft repo
    if [ -n "$UBUNTU_CODENAME" ]; then
        VERSION_FOR_REPO="$VERSION_ID"
    elif [ -n "$VERSION_CODENAME" ]; then
        # Debian-based distros (Kali, Parrot) often base on a specific Debian version
        # Use the upstream Ubuntu 24.04 repo as fallback
        VERSION_FOR_REPO="24.04"
    else
        VERSION_FOR_REPO="24.04"
    fi

    # Skip if a Microsoft repo is already configured (e.g. REMnux ships microsoft.sources)
    if ls /etc/apt/sources.list.d/microsoft*.sources /etc/apt/sources.list.d/microsoft*.list 2>/dev/null | grep -q .; then
        echo "Microsoft repo already configured — skipping packages-microsoft-prod.deb"
    else
        wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_FOR_REPO}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb 2>&1 || \
            wget -q "https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb 2>&1
        dpkg -i /tmp/packages-microsoft-prod.deb
        rm -f /tmp/packages-microsoft-prod.deb
    fi
    apt-get update -y -qq
    apt-get install -y -qq powershell 2>&1

elif is_fedora; then
    # Microsoft repo for Fedora/RHEL
    rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>&1
    dnf install -y -q https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm 2>&1 || \
        dnf install -y -q https://packages.microsoft.com/config/fedora/40/packages-microsoft-prod.rpm 2>&1
    dnf install -y -q powershell 2>&1

elif is_suse; then
    rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>&1
    zypper addrepo https://packages.microsoft.com/rhel/9/prod/ microsoft-prod 2>&1 || true
    zypper install -y powershell 2>&1

elif is_arch; then
    # PowerShell is available in AUR; use the static binary as fallback
    if command -v yay >/dev/null 2>&1; then
        yay -S --noconfirm powershell-bin 2>&1
    else
        # Direct install from GitHub releases (pinned version + checksum)
        PWSH_VERSION="7.5.5"
        PWSH_SHA256="39A62F466956E3606AEE6637ED0D0735C1ED27612A76DE973B111530DDFF2E77"
        curl -sL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz" -o /tmp/pwsh.tar.gz
        echo "${PWSH_SHA256}  /tmp/pwsh.tar.gz" | sha256sum -c - || { echo "ERROR: PowerShell checksum mismatch"; exit 1; }
        mkdir -p /opt/microsoft/powershell/7
        tar xzf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell/7
        chmod +x /opt/microsoft/powershell/7/pwsh
        ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
        rm -f /tmp/pwsh.tar.gz
    fi

else
    echo "Unknown distribution: $ID (ID_LIKE: ${ID_LIKE:-none}) — skipping PowerShell installation"
    exit 1
fi

###############################################################################
# Verify installation
###############################################################################
if ! command -v pwsh >/dev/null 2>&1; then
    echo "ERROR: pwsh not found after installation"
    exit 1
fi

echo "PowerShell installed: $(pwsh --version 2>&1)"

###############################################################################
# Configure SSH subsystem for PowerShell remoting
###############################################################################
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    # Remove any existing powershell subsystem line to avoid duplicates
    sed -i '/^Subsystem.*powershell/d' "$SSHD_CONFIG"
    # Add the PowerShell SSH subsystem
    echo "Subsystem powershell /usr/bin/pwsh -sshs -NoLogo -NoProfile" >> "$SSHD_CONFIG"
    echo "PowerShell SSH subsystem configured in $SSHD_CONFIG"
else
    echo "WARNING: $SSHD_CONFIG not found — SSH subsystem not configured"
fi

echo "install_pwsh.sh completed successfully"
