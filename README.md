# ublue-docker-host

Headless [bootc](https://github.com/bootc-dev/bootc)/[Universal Blue](https://universal-blue.org/) image based on
[uCore-minimal](https://github.com/ublue-os/ucore) (Fedora CoreOS). No desktop, docker + compose ready to use,
SMB/NFS mount clients, passwordless sudo for `wheel`, and optional [cloud-init](https://cloud-init.io/) provisioning
that works both as a Proxmox VM template and on bare metal.

This repo is a customization built on top of the
[ublue-os/image-template](https://github.com/ublue-os/image-template) workflow: a `Containerfile` + GitHub Actions
build it, sign it, push it to GHCR, and turn it into bootable qcow2/raw disk images via
[bootc-image-builder](https://osbuild.org/docs/bootc/).

## What's different from stock uCore-minimal

- `docker.socket` enabled (uCore ships real docker/moby-engine + `docker compose` + `docker buildx`, but disables
  the socket by default). That's all that's needed — `dockerd` starts on demand via socket activation; enabling
  `docker.service` directly is a no-op since its upstream preset re-disables it on first boot regardless — see
  [`build_files/build.sh`](build_files/build.sh)
- `cloud-init` installed and enabled (uCore normally expects Ignition, which Proxmox doesn't support natively;
  cloud-init is added on top instead — Ignition is simply left unused)
- `cifs-utils`, `nfs-utils` installed so you can `mount -t cifs` / `mount -t nfs` shares
- `%wheel` gets passwordless sudo (`system_files/etc/sudoers.d/wheel-nopasswd`)
- cloud-init is restricted to the `NoCloud` and `ConfigDrive` datasources, with `None` as a no-op fallback so boot
  never blocks waiting for a datasource that isn't there — see
  [`system_files/etc/cloud/cloud.cfg.d/99-datasources.cfg`](system_files/etc/cloud/cloud.cfg.d/99-datasources.cfg)
- cloud-init's `package_update_upgrade_install` and `growpart`/`resizefs` modules are disabled — see
  [`system_files/etc/cloud/cloud.cfg.d/99-bootc-modules.cfg`](system_files/etc/cloud/cloud.cfg.d/99-bootc-modules.cfg)
  and "Growing the root filesystem" below
- `qemu-guest-agent` enabled (already installed by uCore, but off by default) so Proxmox can report the VM's IP
  and `qm guest exec` works

## Verified on real hardware

Built and booted end-to-end as a Proxmox VE 9.2 VM (qcow2, imported disk + CloudInit drive, `vmbr0`/DHCP): boots in
under 20s, cloud-init provisions the user/SSH key via Proxmox's NoCloud drive, `%wheel` sudo is passwordless,
`docker run`, `docker compose up`, and `docker buildx version` all work, and `mount.cifs`/`mount.nfs` are present
with the `cifs`/`nfs` kernel modules loadable. Two real issues turned up along the way and are already fixed in this
repo (see `build_files/build.sh` and the cloud-init drop-ins above):

1. uCore's embedded partition layout (`/usr/lib/image-builder/bootc/disk.yaml`) sets a root-fs `mkfs_options.agcount`
   field that the public `quay.io/centos-bootc/bootc-image-builder:latest` release (unchanged since 2026-06-18)
   doesn't parse yet, hard-failing manifest generation. `build.sh` strips that field during the build.
2. Fedora's default cloud-init module list runs `dnf -y upgrade` on every boot (`package_update_upgrade_install`),
   which fails outright against a read-only bootc/ostree root — updates on this OS go through `bootc upgrade` /
   `rpm-ostree upgrade` instead (uCore already automates that via `rpm-ostreed-automatic.timer`). Disabled via the
   `99-bootc-modules.cfg` drop-in, along with `growpart`/`resizefs` (see below).
3. `bootc-image-builder --rootfs=btrfs` builds a qcow2 without error, but the resulting VM hangs in GRUB right after
   `Probing EDD (edd=off to disable)... ok` and never reaches the kernel (confirmed via screendump + 0% CPU for
   6+ minutes on real Proxmox hardware). `--rootfs=xfs` — uCore's own choice, per its embedded
   `/usr/lib/image-builder/bootc/disk.yaml` — boots in ~20s. `Justfile` and `build-disk.yml` are pinned to
   `--rootfs=xfs` rather than the image-template's usual `btrfs` default for this reason; hasn't been root-caused
   further (likely GRUB's btrfs module/subvolume handling for this image), so treat re-enabling btrfs as unverified.

## Growing the root filesystem

cloud-init's usual auto-resize doesn't work here: its `growpart`/`resizefs` modules can't map the `/` mountpoint
back to a block device through the composefs overlay bootc/ostree uses, so they're disabled rather than left to
fail noisily every boot. The root partition is sized once at image-build time via
[`disk_config/disk.toml`](disk_config/disk.toml)'s `minsize`. If you later enlarge the underlying disk (e.g.
`qm resize 9000 scsi0 +50G` on Proxmox), grow it manually instead:

```bash
sudo growpart /dev/sda 4   # partition 4 is "root" - check with `lsblk` / `sudo sfdisk -l /dev/sda`
sudo xfs_growfs /
```

## Step 1: Push this to your own GitHub repo

```bash
cd ~/ublue-docker-host
git init -b main
git add -A
git commit -m "Initial setup"
```

Create an empty repo on GitHub (no README/license/gitignore), then:

```bash
git remote add origin git@github.com:<youruser>/ublue-docker-host.git
git push -u origin main
```

Enable Actions for the repo (`Actions` tab → enable workflows).

## Step 2: Container signing (required, builds fail without it)

```bash
cd ~/ublue-docker-host
COSIGN_PASSWORD="" cosign generate-key-pair
gh secret set SIGNING_SECRET < cosign.key
git add cosign.pub
git commit -m "Add cosign public key"
git push
```

`cosign.key` is git-ignored on purpose — never commit it.

## Step 3: Set your GitHub username

Edit [`image-template.env`](image-template.env) and replace `REPO_ORGANIZATION="changeme"` with your GitHub
username/org, then commit and push. The `build.yml` workflow then builds and publishes
`ghcr.io/<youruser>/ublue-docker-host:latest`.

## Step 4: Build disk images

Trigger the **Build disk images** workflow manually (`Actions` → `Build disk images` → `Run workflow`, pick
`amd64` or `arm64`). It produces `qcow2` and `raw` images as workflow artifacts (or uploads to S3 if you configure
that, see the template's own docs for the S3 secrets).

Alternatively build locally with `just` + `podman` (needs Linux + KVM):

```bash
just build                # build the OCI image locally
just build-qcow2          # -> output/qcow2/disk.qcow2
just build-raw            # -> output/raw/disk.raw
```

### Proxmox (qcow2)

1. Upload `disk.qcow2` to a Proxmox node and import it as a VM disk (`qm importdisk <vmid> disk.qcow2 <storage>`),
   or create the VM first and import into it.
2. Attach a **CloudInit drive** to the VM (Proxmox UI: Hardware → Add → CloudInit Drive).
3. Set the Proxmox Cloud-Init tab (user, SSH key, IP config) as usual — this is exactly the `NoCloud`/`ConfigDrive`
   data cloud-init reads on first boot.
4. Boot the VM.

### Bare metal (raw)

- `dd if=disk.raw of=/dev/sdX bs=4M status=progress` onto the target disk, **or**
- boot the machine from the raw image on a USB stick the same way.
- Cloud-init on real hardware needs a `NoCloud` seed: create a small ISO/USB drive labeled `cidata` containing
  `user-data` and `meta-data` files ([cloud-init NoCloud docs](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html))
  and attach it at first boot. Without one, the machine just boots normally (see the commented-out fallback user in
  [`disk_config/disk.toml`](disk_config/disk.toml) if you want a guaranteed local login instead).

## Updating an already-installed machine

Once a machine is running this image, ship changes just by pushing to `main` — the daily/PR-merge build produces a
new image, and `rpm-ostree` / `bootc` on the machine picks it up automatically (uCore enables
`rpm-ostreed-automatic.timer` with staged updates). To move an existing uCore/Fedora bootc machine onto this image
for the first time:

```bash
sudo bootc switch ghcr.io/<youruser>/ublue-docker-host:latest
sudo reboot
```

## Notes

- uCore explicitly recommends not running podman and docker containers on the same host at the same time; podman
  stays installed (cockpit and some system bits use it) but is otherwise unused if you go all-in on docker/compose.
- To add more packages or tweaks, edit [`build_files/build.sh`](build_files/build.sh); to ship extra config files,
  drop them under `system_files/` mirroring their absolute path (e.g. `system_files/etc/foo.conf` → `/etc/foo.conf`).
