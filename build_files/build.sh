#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### Install packages

# cloud-init          - optional first-boot provisioning (Proxmox cloud-init drive & bare-metal NoCloud seed)
# cloud-utils-growpart - manual `growpart` after enlarging the disk later (see README: cloud-init's own
#                        growpart/resizefs modules can't map "/" through the composefs root mount, so
#                        they're disabled in 99-bootc-modules.cfg rather than failing noisily every boot)
# cifs-utils           - mount SMB/CIFS shares
# nfs-utils            - mount NFS shares
# wget1-wget           - Fedora split classic wget into wget1/wget2; this is the shim package that
#                        actually provides the /usr/bin/wget binary
# python3.12           - pinned version alongside the image default (3.14), for tooling that needs it
dnf5 install -y \
    cloud-init \
    cloud-utils-growpart \
    cifs-utils \
    nfs-utils \
    wget1-wget \
    python3.12 \
    chezmoi \
    git \
    helix \
    helix-parsers \
    helix-themes \
    lsd \
    btop \
    bat

# python3.12 has no python3.12-pip package; ensurepip provides it, but it installs into
# /usr/local (-> /var/usrlocal on this ostree/bootc layout), which only gets created by
# tmpfiles.d at boot - doesn't exist yet during the image build, so ensurepip fails with
# "No such file or directory: '/usr/local/lib'" unless we create it ourselves first.
mkdir -p /var/usrlocal/{bin,etc,games,include,lib,lib64,libexec,sbin,share,src}
python3.12 -m ensurepip --upgrade

### Docker
# uCore already ships moby-engine (real docker, not just podman) plus the
# docker-buildx and docker-compose (v2 "docker compose") CLI plugins, but
# disables docker.socket by default to avoid clashing with podman.
# Enabling docker.socket is enough: dockerd starts on-demand on first use via
# socket activation. docker.service itself ships disabled by upstream preset
# and that's re-applied on first boot regardless of what we set here at
# build time, so enabling it directly is a no-op - don't bother.
systemctl enable docker.socket

# qemu-guest-agent is already installed by uCore-minimal but not enabled by
# default; needed for Proxmox to report the VM's IP / support `qm guest exec`.
systemctl enable qemu-guest-agent.service

### cloud-init
# The package's own postinstall already wires cloud-init.target.wants up to
# cloud-init-local/cloud-init-main/cloud-config/cloud-final; enable explicitly
# anyway so this doesn't silently regress if that ever changes upstream. With
# no datasource attached (see 99-datasources.cfg) these just no-op, so
# cloud-init stays fully optional.
systemctl enable cloud-init-local.service
systemctl enable cloud-init-main.service
systemctl enable cloud-config.service
systemctl enable cloud-final.service

### growroot
# system_files/usr/libexec/growroot + .../growroot.service were just copied in
# above. Replaces cloud-init's own growpart/resizefs modules, which are
# disabled here because they can't resolve "/" through the composefs overlay
# (see 99-bootc-modules.cfg and README "Growing the root filesystem").
chmod 0755 /usr/libexec/growroot
systemctl enable growroot.service

### passwordless sudo for wheel
# system_files/etc/sudoers.d/wheel-nopasswd was just copied in above.
# Git doesn't preserve exact permission bits, and sudo refuses group/world
# writable files in sudoers.d, so fix perms and validate syntax explicitly.
chmod 0440 /etc/sudoers.d/wheel-nopasswd
visudo -cf /etc/sudoers.d/wheel-nopasswd

### bootc-image-builder compat
# uCore's embedded partition layout (/usr/lib/image-builder/bootc/disk.yaml)
# currently sets root fs mkfs_options.agcount, a field the public
# quay.io/centos-bootc/bootc-image-builder:latest release (unchanged since
# 2026-06-18) doesn't understand yet, which hard-fails manifest generation.
# Drop it; everything else about CoreOS's hybrid BIOS+UEFI layout is untouched.
sed -i '/mkfs_options:/,+1d' /usr/lib/image-builder/bootc/disk.yaml

### Remove desktop/Ignition tooling not needed on a headless Proxmox VM

# setroubleshoot-server is a GUI tool that explains SELinux denials in plain
# text — useful on a desktop, just journal spam on a headless server. Its
# python3-six dependency is also missing in the base image, producing a second
# error on every single AVC denial.
# mkdir first: RPM scriptlets try to remove /var/lib/setroubleshoot and
# /run/setroubleshoot at uninstall time; those dirs don't exist in the build
# container, causing scriptlet failures that abort the build under set -e.
mkdir -p /var/lib/setroubleshoot /run/setroubleshoot
dnf5 remove -y setroubleshoot-server setroubleshoot-plugins

# coreos-sshd-generator runs `sshd -G` during early boot to generate an
# AuthorizedKeysFile drop-in that includes Ignition/Afterburn ephemeral key
# paths. SELinux blocks sshd execution in the generator context, producing
# repeated AVC denials. cloud-init handles SSH key injection here, so the
# generator serves no purpose.
mkdir -p /etc/systemd/system-generators
ln -sf /dev/null /etc/systemd/system-generators/coreos-sshd-generator

### Updates
# Zincati (CoreOS auto-updater) requires ignition.platform.id on the kernel
# cmdline, absent on qcow2-provisioned VMs. Disable it here; 50-ublue-docker-host
# .preset enforces the disable on every deployment so it can't be re-enabled by
# an upstream preset change.
# rpm-ostreed-automatic.timer replaces it: stages new OCI image versions from
# GHCR in the background, same as Bazzite's uupd mechanism.
# ublue-rebase-ghcr runs once on first boot to switch the remote from the
# localhost/ reference baked in by bootc-image-builder to ghcr.io.
chmod 0755 /usr/libexec/ublue-rebase-ghcr

### cleanup
# /run is tmpfs at actual boot; anything package scriptlets left here during
# the build is stale and shouldn't ship in the image. (Don't blanket-wipe
# /run/* - buildah keeps active bind mounts there, e.g. /run/secrets.)
rm -rf /run/cloud-init /run/dnf
