#!/bin/bash
set -e

echo "=== OneKey Pro Firmware Verification ==="

# Download official firmware
echo "1. Downloading official firmware..."
mkdir -p verification && cd verification
wget -q -O official.signed.bin "https://github.com/OneKeyHQ/firmware-pro/releases/download/v4.14.0/pro.4.14.0-Stable-0704-f23570e_1.1.5_dfc6ccf_0x10_1.1.6_dfcd608_0x13.signed.bin"

# Extract official firmware
echo "2. Extracting official firmware..."
cat > extract.sh << 'EOF'
#!/bin/bash
INPUT="$1"
MAGIC=$(dd if="$INPUT" bs=1 count=4 2>/dev/null)

if [[ "$MAGIC" == "TRZF" ]]; then
    SIZE=$(dd if="$INPUT" bs=1 skip=12 count=4 2>/dev/null | od -An -tu4)
    TOTAL=$((SIZE + 1024))
elif [[ "$MAGIC" == "OKTV" ]]; then
    HEAD1=$(dd if="$INPUT" bs=1 skip=4 count=4 2>/dev/null | od -An -tu4 | tr -d ' ')
    SIZE=$(dd if="$INPUT" bs=1 skip=$((HEAD1 + 12)) count=4 2>/dev/null | od -An -tu4)
    TOTAL=$((HEAD1 + 1024 + SIZE))
else
    echo "Unknown format"
    exit 1
fi
dd if="$INPUT" bs=1 count="$TOTAL" of="$2" 2>/dev/null
EOF

chmod +x extract.sh
./extract.sh official.signed.bin official.bin

# Get official hash
echo "3. Calculating official firmware hash..."
OFFICIAL_HASH=$(tail -c +2561 official.bin | sha256sum | cut -d' ' -f1)
echo "Official hash: $OFFICIAL_HASH"

# Build firmware with Docker - fix NIX_PATH issue
echo "4. Building firmware with Docker..."
CONTAINER="onekey-verify-$$"

docker run -d --name "$CONTAINER" onekey-firmware-builder sleep 3600

# Fix NIX_PATH and build
echo "5. Running build inside container..."
docker exec "$CONTAINER" bash -c '
    export NIX_PATH="nixpkgs=https://github.com/NixOS/nixpkgs/archive/nixos-24.05.tar.gz"
    cd /home/builder/firmware-pro
    . /home/builder/.nix-profile/etc/profile.d/nix.sh
    echo "Building firmware..."
    PRODUCTION=1 nix-shell --run "poetry run make -C core build_firmware"
'

# Copy built firmware
echo "6. Copying built firmware..."
mkdir -p built
docker cp "$CONTAINER:/home/builder/firmware-pro/core/build/firmware/." ./built/
docker rm -f "$CONTAINER"

# Find and hash built firmware
BUILT_FILE=$(ls built/pro.*.bin 2>/dev/null | head -1)
if [ ! -f "$BUILT_FILE" ]; then
    echo "ERROR: Built firmware not found"
    ls -la built/
    exit 1
fi

echo "7. Calculating built firmware hash..."
BUILT_HASH=$(tail -c +2561 "$BUILT_FILE" | sha256sum | cut -d' ' -f1)
echo "Built hash:    $BUILT_HASH"

# Compare results
echo ""
echo "=== VERIFICATION RESULT ==="
echo "Official: $OFFICIAL_HASH"
echo "Built:    $BUILT_HASH"
echo ""

if [ "$OFFICIAL_HASH" = "$BUILT_HASH" ]; then
    echo "✅ SUCCESS: Reproducible build verified!"
    echo "The firmware is identical to the official release."
else
    echo "❌ FAILED: Hashes do not match"
    echo "The build is not reproducible."
fi

echo ""
echo "Expected hash: aa0250f6ccc21dc089d7d25d80f6c38beae40e9c183d8c4b9898cadbb25fcbd9"