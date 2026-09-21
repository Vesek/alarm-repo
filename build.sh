#!/bin/sh
docker buildx build -o type=local,dest=./dist .
