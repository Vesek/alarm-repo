# syntax=docker/dockerfile:1.6
#
# Native aarch64 build for packages that need a full rootfs to link against.
# Uses the official Arch Linux ARM tarball as the base.
#
# Requires QEMU binfmt support on the host:
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# Build:
#   docker buildx build -f Dockerfile.chroot -o type=local,dest=./dist-chroot .

FROM --platform=$BUILDPLATFORM alpine:3.20 AS fetcher

ARG ALARM_TARBALL_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

RUN apk add --no-cache curl tar \
    && mkdir -p /rootfs \
    && curl -fSL "${ALARM_TARBALL_URL}" -o /tmp/alarm.tar.gz \
    && tar -xpf /tmp/alarm.tar.gz -C /rootfs --numeric-owner \
    && rm -f /tmp/alarm.tar.gz

FROM scratch AS builder

COPY --from=fetcher /rootfs/ /

# Initialize pacman keyring, remove useless kernel/firmware, and install build tools
RUN pacman-key --init && \
    pacman-key --populate archlinuxarm && \
    pacman -Rnsc --noconfirm linux-aarch64 linux-firmware mkinitcpio || true && \
    pacman -Syu --noconfirm --disable-sandbox base-devel meson git xz distcc

# DisableSandbox is needed for pacman under QEMU emulation.
RUN mkdir -p /build/repo && \
    printf '\n[localrepo]\nServer = file:///build/repo\nSigLevel = Optional TrustAll\n' >> /etc/pacman.conf && \
    sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

# Copy previously built packages from host to act as dependencies for this build
COPY dist/aarch64/ /build/repo/
RUN sh -c 'cd /build/repo && rm -f *.db* *.files* && repo-add localrepo.db.tar.gz *.pkg.tar* 2>/dev/null || repo-add localrepo.db.tar.gz'

# Create an unprivileged build user (makepkg refuses to run as root)
RUN useradd -m -d /build builduser && chown -R builduser:builduser /build

ARG GITHUB_LOGIN
ARG GITHUB_PAT
RUN if [ -n "$GITHUB_LOGIN" ] && [ -n "$GITHUB_PAT" ]; then \
        printf "machine github.com\nlogin %s\npassword %s\nmachine api.github.com\nlogin %s\npassword %s\nmachine codeload.github.com\nlogin %s\npassword %s\nmachine objects.githubusercontent.com\nlogin %s\npassword %s\n" \
        "${GITHUB_LOGIN}" "${GITHUB_PAT}" "${GITHUB_LOGIN}" "${GITHUB_PAT}" "${GITHUB_LOGIN}" "${GITHUB_PAT}" "${GITHUB_LOGIN}" "${GITHUB_PAT}" > /build/.netrc && \
        chmod 600 /build/.netrc && \
        chown builduser:builduser /build/.netrc; \
    fi

# Configure makepkg to use .netrc and distcc
ARG DISTCC_HOST
RUN sed -i 's/^DLAGENTS=(/DLAGENTS=(/' /etc/makepkg.conf && \
    sed -i -E "s/(https?::.*curl.*) -o %o %u/\1 --netrc-optional -o %o %u/g" /etc/makepkg.conf && \
    sed -i 's/!distcc/distcc/g' /etc/makepkg.conf && \
    sed -i 's/^#MAKEFLAGS="-j2"/MAKEFLAGS="-j16"/g' /etc/makepkg.conf && \
    sed -i 's/^#DISTCC_HOSTS=""/DISTCC_HOSTS="'"$DISTCC_HOST"'"/g' /etc/makepkg.conf && \
    echo "DISTCC_HOSTS=\"$DISTCC_HOST\"" >> /etc/makepkg.conf && \
    echo "MAKEFLAGS=\"-j16\"" >> /etc/makepkg.conf && \
    sed -i 's/^PKGEXT=.*/PKGEXT=".pkg.tar"/g' /etc/makepkg.conf && \
    sed -i 's/ lto / !lto /g' /etc/makepkg.conf && \
    for arch in aarch64 arm64ec x86_64 i686; do \
        ln -s /usr/bin/distcc /usr/lib/distcc/bin/${arch}-w64-mingw32-clang; \
        ln -s /usr/bin/distcc /usr/lib/distcc/bin/${arch}-w64-mingw32-clang++; \
        ln -s /usr/bin/distcc /usr/lib/distcc/bin/${arch}-w64-mingw32-gcc; \
        ln -s /usr/bin/distcc /usr/lib/distcc/bin/${arch}-w64-mingw32-g++; \
    done

ARG SUBSET
# Copy all package sources from the selected subset
COPY --chown=builduser:builduser PKGBUILDs/${SUBSET}/ /build/src/

# Build packages with automatic dependency resolution via the local repo.
RUN set -eu; \
    pacman -Sy; \
    remaining=""; \
    for d in /build/src/*/; do [ -f "${d}PKGBUILD" ] && remaining="$remaining $d"; done; \
    \
    round=1; \
    while [ -n "$remaining" ] && [ "$round" -le 10 ]; do \
        echo "===== Build round $round ====="; \
        failed=""; progress=false; \
        for pkgdir in $remaining; do \
            pkgname=$(basename "$pkgdir"); \
            echo "---- Attempting: $pkgname ----"; \
            cd "$pkgdir"; \
            deps=$(bash -c 'source PKGBUILD; echo "${makedepends[@]} ${depends[@]}"'); \
            deps_clean=$(echo "$deps" | xargs); \
            if [ -n "$deps_clean" ] && ! pacman -S --noconfirm --needed $deps_clean 2>&1; then \
                echo "---- Deferred: $pkgname (deps not available) ----"; \
                failed="$failed $pkgdir"; \
                continue; \
            fi; \
            if runuser -u builduser -- makepkg --noconfirm --cleanbuild 2>&1; then \
                echo "---- Built: $pkgname ----"; \
                cp *.pkg.tar* /build/repo/; \
                repo-add /build/repo/localrepo.db.tar.gz /build/repo/*.pkg.tar*; \
                pacman -Sy --noconfirm; \
                progress=true; \
            else \
                echo "---- Deferred: $pkgname ----"; \
                failed="$failed $pkgdir"; \
            fi; \
        done; \
        remaining="$failed"; \
        round=$((round + 1)); \
        if [ "$progress" = "false" ] && [ -n "$remaining" ]; then \
            echo "ERROR: no progress in round $((round-1)), cannot resolve: $remaining"; \
            exit 1; \
        fi; \
    done; \
    echo "===== All chroot packages built ====="; \
    mkdir -p /build/export; \
    cp /build/repo/*.pkg.tar* /build/export/

FROM scratch AS exporter
COPY --from=builder /build/export/ /aarch64/
