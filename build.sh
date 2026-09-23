#!/bin/sh
set -e

git submodule update --init --recursive
ARCHIVE=false
GITHUB_LOGIN=""
GITHUB_PAT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --login)
            GITHUB_LOGIN="$2"
            shift 2
            ;;
        --pat)
            GITHUB_PAT="$2"
            shift 2
            ;;
        --archive|-a)
            ARCHIVE=true
            shift 1
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

BUILD_ARGS=""
if [ -n "$GITHUB_LOGIN" ] && [ -n "$GITHUB_PAT" ]; then
    BUILD_ARGS="--build-arg GITHUB_LOGIN=$GITHUB_LOGIN --build-arg GITHUB_PAT=$GITHUB_PAT"
fi

# Build the cross-compiled packages and output to ./dist
echo "==== Building cross-compiled packages with Docker ===="
docker buildx build $BUILD_ARGS -f Dockerfile -o type=local,dest=./dist .

# Build the chroot packages (native aarch64 via QEMU) and output to ./dist-chroot
echo "==== Building chroot packages with Docker ===="
docker buildx build $BUILD_ARGS -f Dockerfile-chroot -o type=local,dest=./dist-chroot .

# Merge chroot packages into the main repo
echo "==== Merging chroot packages into repository ===="
cp dist-chroot/aarch64/*.pkg.tar.* dist/aarch64/
rm -rf dist-chroot

# Regenerate the repo database with all packages combined
echo "==== Regenerating repository database ===="
docker run --rm -v "$(pwd)/dist/aarch64:/repo" archlinux:base-devel \
    sh -c 'cd /repo && rm -f alarm-sm7150.db* alarm-sm7150.files* && repo-add alarm-sm7150.db.tar.gz *.pkg.tar.*'

# Check if the user requested to compress the output
if [ "$ARCHIVE" = true ]; then
    echo "==== Compressing the output repository ===="
    cd dist
    tar -czvf alarm-sm7150-repo.tar.gz aarch64/
    echo "Success! Archive created at dist/alarm-sm7150-repo.tar.gz"
else
    echo "Success! Raw files are in dist/aarch64/"
fi
