#!/bin/bash
set -e

# Update submodules if any
git submodule update --init --recursive || true

GITHUB_LOGIN=""
GITHUB_PAT=""

# Parse CLI arguments for GitHub credentials
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
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Find subsets
if [ ! -d "PKGBUILDs" ]; then
    echo "Error: PKGBUILDs directory not found."
    exit 1
fi

SUBSETS=$(find PKGBUILDs -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
if [ -z "$SUBSETS" ]; then
    echo "Error: No subset folders found inside PKGBUILDs/"
    exit 1
fi

# Build whiptail menu options
MENU_OPTIONS=()
for s in $SUBSETS; do
    MENU_OPTIONS+=("$s" "Build the '$s' subset")
done
MENU_OPTIONS+=("repo-add" "Rebuild repository database only (no compile)")

CHOICE=$(whiptail --title "ALARM Build System" --menu "Choose an action:" 15 65 6 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

if [ -z "$CHOICE" ]; then
    echo "Cancelled."
    exit 0
fi

if [ "$CHOICE" = "repo-add" ]; then
    echo "==== Regenerating repository database ===="
    docker run --rm -v "$(pwd)/dist/aarch64:/repo" archlinux:base-devel \
        sh -c 'cd /repo && rm -f alarm-sm7150.db* alarm-sm7150.files* && repo-add alarm-sm7150.db.tar.gz *.pkg.tar*'
    
    if whiptail --title "Archive" --yesno "Database updated! Would you like to compress the output repository?" 8 65; then
        echo "==== Compressing the output repository ===="
        cd dist
        tar -czvf alarm-sm7150-repo.tar.gz aarch64/
        echo "Success! Archive created at dist/alarm-sm7150-repo.tar.gz"
    else
        echo "Success! Database updated in dist/aarch64/"
    fi
    exit 0
fi

# We are building a subset
SUBSET="$CHOICE"
echo "==== Selected subset: $SUBSET ===="

BUILD_ARGS=""
if [ -n "$GITHUB_LOGIN" ] && [ -n "$GITHUB_PAT" ]; then
    BUILD_ARGS="--build-arg GITHUB_LOGIN=$GITHUB_LOGIN --build-arg GITHUB_PAT=$GITHUB_PAT"
fi
BUILD_ARGS="$BUILD_ARGS --build-arg SUBSET=$SUBSET"

cleanup() {
    echo "==== Cleaning up distccd helper ===="
    docker stop alarm-distccd >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==== Starting native distccd helper ===="
docker build -t alarm-distccd-helper -f Dockerfile.distccd .
docker stop alarm-distccd >/dev/null 2>&1 || true
docker run -d --rm --name alarm-distccd --network host alarm-distccd-helper

DISTCC_HOST="127.0.0.1"
echo "distccd helper running at $DISTCC_HOST"

BUILD_ARGS="$BUILD_ARGS --build-arg DISTCC_HOST=$DISTCC_HOST --network host"

echo "==== Building subset '$SUBSET' with Docker ===="
mkdir -p dist/aarch64
touch dist/aarch64/.keep
docker buildx build $BUILD_ARGS -f Dockerfile -o type=local,dest=./dist .

echo "==== Regenerating repository database ===="
docker run --rm -v "$(pwd)/dist/aarch64:/repo" archlinux:base-devel \
    sh -c 'cd /repo && rm -f alarm-sm7150.db* alarm-sm7150.files* && repo-add alarm-sm7150.db.tar.gz *.pkg.tar*'

echo "Success! Packages are in dist/aarch64/"
