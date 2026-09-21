# syntax=docker/dockerfile:1.6

FROM archlinux:base-devel AS builder

# Install cross-compiler and sudo
RUN pacman -Syu --noconfirm aarch64-linux-gnu-gcc sudo

# Create a build user
RUN useradd -m -d /build builduser && \
    echo 'builduser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builduser

USER builduser
WORKDIR /build

# Copy the makepkg config
COPY --chown=builduser:builduser aarch64-makepkg.conf /build/

# Copy the entire packages directory (including all subdirectories)
COPY --chown=builduser:builduser PKGBUILDs /build/src/

# Setup cross-compilation environment
ENV ARCH=arm64
ENV CROSS_COMPILE=aarch64-linux-gnu-

# Loop over all directories, build them, and create the repo database
RUN set -eux; \
    mkdir -p /build/repo/aarch64; \
    for pkgdir in /build/src/*/; do \
        # Check if the directory has a PKGBUILD
        if [ -f "${pkgdir}PKGBUILD" ]; then \
            echo "==== Building package in ${pkgdir} ===="; \
            cd "${pkgdir}"; \
            makepkg --config /build/aarch64-makepkg.conf --ignorearch --syncdeps --noconfirm; \
            # Move all generated package files to our repo directory
            mv *.pkg.tar.* /build/repo/aarch64/; \
        fi; \
    done; \
    \
    echo "==== Generating Repository Database ===="; \
    cd /build/repo/aarch64; \
    # Ensure packages exist, then generate the DB
    if ls *.pkg.tar.* >/dev/null 2>&1; then \
        repo-add alarm-sm7150.db.tar.gz *.pkg.tar.*; \
    else \
        echo "Error: No packages were built!"; \
        exit 1; \
    fi; \
    \
    echo "==== Creating Archive ===="; \
    cd /build/repo; \
    # Create a compressed tarball of the entire aarch64 directory
    tar -czvf /build/alarm-sm7150-repo.tar.gz aarch64/

# Export the archive to the host
FROM scratch AS exporter
COPY --from=builder /build/alarm-sm7150-repo.tar.gz /
