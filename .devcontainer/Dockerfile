FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Set up timezone and locale
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# Update package lists
RUN apt-get update

# Install ISO Build Tools (required for building custom Ubuntu Live ISO)
RUN apt-get install -y --no-install-recommends \
    debootstrap \
    squashfs-tools \
    xorriso \
    grub-pc-bin \
    grub-efi-amd64-bin \
    grub-efi-amd64-signed \
    shim-signed \
    syslinux \
    syslinux-common \
    mtools \
    dosfstools \
    isolinux \
    genisoimage

# Install Development Tools
RUN apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    vim \
    sudo

# Install Testing Tools
RUN apt-get install -y --no-install-recommends \
    shellcheck \
    bats-core

# Install Node.js LTS
RUN apt-get install -y --no-install-recommends \
    nodejs \
    npm

# Install Bun (needed for oh-my-opencode)
RUN curl -fsSL https://bun.sh/install | bash

# Clean up apt cache to reduce image size
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure Bun is in PATH
ENV PATH="/root/.bun/bin:$PATH"
