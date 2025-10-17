#!/bin/bash

set -e

WORK_DIR="/tmp/blixt-test-$(date +%s)"

echo "Testing Blixt Wallet build..."

# Check Docker and clone
command -v docker >/dev/null || { echo "ERROR: Docker required"; exit 1; }
git clone https://github.com/hsjoberg/blixt-wallet.git "$WORK_DIR"
cd "$WORK_DIR"

# Test official build
yarn install
chmod +x build.sh

if ./build.sh; then
    echo "SUCCESS: Build works"
    find . -name "*.apk" -type f 2>/dev/null | head -3
else
    echo "FAILURE: FTBFS confirmed"
    exit 1
fi