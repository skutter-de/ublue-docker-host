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
dnf5 install -y \
    cloud-init \
    cloud-utils-growpart \
    cifs-utils \
    nfs-utils

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

### cleanup
# /run is tmpfs at actual boot; anything package scriptlets left here during
# the build is stale and shouldn't ship in the image. (Don't blanket-wipe
# /run/* - buildah keeps active bind mounts there, e.g. /run/secrets.)
rm -rf /run/cloud-init /run/dnf
