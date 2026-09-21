#!/bin/sh
set -e

# Build the packages and output raw files to ./dist
echo "==== Building packages with Docker ===="
docker buildx build -o type=local,dest=./dist .

# Check if the user passed an argument to compress the output
if [ "$1" = "--archive" ] || [ "$1" = "-a" ]; then
    echo "==== Compressing the output repository ===="
    cd dist
    tar -czvf alarm-sm7150-repo.tar.gz aarch64/
    echo "Success! Archive created at dist/alarm-sm7150-repo.tar.gz"
else
    echo "Success! Raw files are in dist/aarch64/"
fi
