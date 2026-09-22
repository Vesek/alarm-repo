#!/bin/sh
set -e

git submodule update --init --recursive

# Build the cross-compiled packages and output to ./dist
echo "==== Building cross-compiled packages with Docker ===="
docker buildx build -f Dockerfile -o type=local,dest=./dist .

# Build the chroot packages (native aarch64 via QEMU) and output to ./dist-chroot
echo "==== Building chroot packages with Docker ===="
docker buildx build -f Dockerfile-chroot -o type=local,dest=./dist-chroot .

# Merge chroot packages into the main repo
echo "==== Merging chroot packages into repository ===="
cp dist-chroot/aarch64/*.pkg.tar.* dist/aarch64/
rm -rf dist-chroot

# Regenerate the repo database with all packages combined
echo "==== Regenerating repository database ===="
docker run --rm -v "$(pwd)/dist/aarch64:/repo" archlinux:base-devel \
    sh -c 'cd /repo && rm -f alarm-sm7150.db* alarm-sm7150.files* && repo-add alarm-sm7150.db.tar.gz *.pkg.tar.*'

# Check if the user passed an argument to compress the output
if [ "$1" = "--archive" ] || [ "$1" = "-a" ]; then
    echo "==== Compressing the output repository ===="
    cd dist
    tar -czvf alarm-sm7150-repo.tar.gz aarch64/
    echo "Success! Archive created at dist/alarm-sm7150-repo.tar.gz"
else
    echo "Success! Raw files are in dist/aarch64/"
fi
