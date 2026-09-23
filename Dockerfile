# syntax=docker/dockerfile:1.6

FROM archlinux:base-devel AS builder

# Add my x86_64 repo so pacman can find build tools like qca-swiss-army-knife
RUN printf '\n[archpkg-tools]\nServer = https://archpkg.vesek.eu/x86_64\nSigLevel = Optional TrustAll\n' >> /etc/pacman.conf

# Install cross-compiler and sudo
RUN pacman -Syu --noconfirm aarch64-linux-gnu-gcc sudo

# Create a build user
RUN useradd -m -d /build builduser && \
    echo 'builduser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builduser

ARG GITHUB_LOGIN
ARG GITHUB_PAT
RUN if [ -n "$GITHUB_LOGIN" ] && [ -n "$GITHUB_PAT" ]; then \
        printf "machine github.com\nlogin %s\npassword %s\nmachine api.github.com\nlogin %s\npassword %s\nmachine codeload.github.com\nlogin %s\npassword %s\nmachine objects.githubusercontent.com\nlogin %s\npassword %s\n" \
        "${GITHUB_LOGIN}" "${GITHUB_PAT}" "${GITHUB_LOGIN}" "${GITHUB_PAT}" "${GITHUB_LOGIN}" "${GITHUB_PAT}" "${GITHUB_LOGIN}" "${GITHUB_PAT}" > /build/.netrc && \
        chmod 600 /build/.netrc && \
        chown builduser:builduser /build/.netrc; \
    fi

USER builduser
WORKDIR /build

# Copy the makepkg config
COPY --chown=builduser:builduser aarch64-makepkg.conf /build/

# Copy the entire packages directory (including all subdirectories)
COPY --chown=builduser:builduser PKGBUILDs /build/src/

# Setup cross-compilation environment
ENV ARCH=arm64
ENV CROSS_COMPILE=aarch64-linux-gnu-

# Loop over all directories, build them, and create the repo database.
# Only makedepends are installed (not runtime depends), since runtime deps
# are aarch64 packages that don't exist on the x86_64 build host.
# Thanks to Claude for realising you can just source the PKGBUILDs
RUN set -eux; \
    mkdir -p /build/repo/aarch64; \
    for pkgdir in /build/src/*/; do \
        if [ -f "${pkgdir}PKGBUILD" ]; then \
            echo "==== Building package in ${pkgdir} ===="; \
            cd "${pkgdir}"; \
            makedeps=$(bash -c 'source PKGBUILD; echo "${makedepends[@]}"'); \
            if [ -n "$makedeps" ]; then \
                sudo pacman -S --noconfirm --needed $makedeps; \
            fi; \
            makepkg --config /build/aarch64-makepkg.conf --ignorearch --nodeps --noconfirm; \
            mv *.pkg.tar.* /build/repo/aarch64/; \
        fi; \
    done; \
    \
    echo "==== Generating Repository Database ===="; \
    cd /build/repo/aarch64; \
    if ls *.pkg.tar.* >/dev/null 2>&1; then \
        repo-add alarm-sm7150.db.tar.gz *.pkg.tar.*; \
    else \
        echo "Error: No packages were built!"; \
        exit 1; \
    fi
    
# Export the raw aarch64 repository folder directly to the host
FROM scratch AS exporter
COPY --from=builder /build/repo/aarch64/ /aarch64/
