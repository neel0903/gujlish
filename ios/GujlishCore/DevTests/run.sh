#!/bin/sh
# Build and run the stand-in tests with plain swiftc. Output goes to
# ios/.build (ignored), never outside the repo.
set -e
cd "$(dirname "$0")/../../.."
mkdir -p ios/.build
swiftc -O -module-cache-path ios/.build/modcache -lsqlite3 -o ios/.build/devtests \
    ios/GujlishCore/Sources/GujlishCore/*.swift \
    ios/GujlishCore/DevTests/main.swift
ios/.build/devtests web/expected.json gujlish.db
