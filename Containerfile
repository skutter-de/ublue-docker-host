# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image: uCore minimal (Fedora CoreOS based, no desktop, bootc/podman/docker preinstalled)
# https://github.com/ublue-os/ucore
#
# Other streams: ghcr.io/ublue-os/ucore-minimal:testing / :lts
FROM ghcr.io/ublue-os/ucore-minimal:stable

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
