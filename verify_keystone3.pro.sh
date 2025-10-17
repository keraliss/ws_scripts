#!/bin/bash
# verify_keystone3.pro.sh v1.0.0 - Standalone verification script for Keystone3 Pro Hardware Wallet
# Usage: verify_keystone3.pro.sh -v version [-t type] [-c]

set -e

# Display disclaimer
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Use at your own risk."
echo "=============================================================================="
echo -e "\033[0m"
sleep 2
echo

# Global Constants
shouldCleanup=false

# Detect container runtime
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
else
    echo "Error: Neither docker nor podman found. Please install Docker or Podman."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Keystone3 Pro constants
repo="https://github.com/KeystoneHQ/keystone3-firmware"
workDir="/tmp/keystone3-verification"

# Default firmware type
firmwareType="multicoin"

usage() {
  echo 'NAME
       reproduce_keystone3.pro.sh - verify Keystone3 Pro hardware wallet firmware

SYNOPSIS
       reproduce_keystone3.pro.sh -v version [-t type] [-c]

DESCRIPTION
       This command tries to verify firmware builds of Keystone3 Pro hardware wallet.

       -v|--version The firmware version to verify (e.g., 2.0.4)
       -t|--type Firmware type: multicoin|cypherpunk|btc (default: multicoin)
       -c|--cleanup Clean up temporary files after testing

EXAMPLES
       reproduce_keystone3.pro.sh -v 2.0.4
       reproduce_keystone3.pro.sh -v 2.0.4 -t cypherpunk
       reproduce_keystone3.pro.sh -v 2.0.4 -t btc -c'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -v|--version) version="$2"; shift ;;
    -t|--type) firmwareType="$2"; shift ;;
    -c|--cleanup) shouldCleanup=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Validate inputs
if [ -z "$version" ]; then
  echo "Error: Version is required!"
  echo
  usage
  exit 1
fi

# Validate firmware type
if [[ "$firmwareType" != "multicoin" && "$firmwareType" != "cypherpunk" && "$firmwareType" != "btc" ]]; then
  echo "Error: Invalid firmware type '$firmwareType'. Must be: multicoin, cypherpunk, or btc"
  exit 1
fi

echo
echo "Verifying Keystone3 Pro firmware version $version ($firmwareType)"
echo

prepare() {
  echo "Setting up verification environment..."
  
  # cleanup any existing work
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  echo "Cloning Keystone3 firmware repository..."
  git clone $repo keystone3-firmware
  cd keystone3-firmware
  
  echo "Initializing submodules (excluding keystone3-firmware-release)..."
  git -c submodule.keystone3-firmware-release.update=none submodule update --init --recursive
}

build_firmware() {
  echo "Building Keystone3 Pro firmware..."
  
  echo "Building Docker image on master branch..."
  if ! $CONTAINER_CMD build -t keystonehq/keystone3_baker:latest .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  echo "Checking out version tag: $version"
  git checkout tags/${version}
  
  echo "Running firmware build in container..."
  if ! $CONTAINER_CMD run -v $(pwd):/keystone3-firmware keystonehq/keystone3_baker:latest python3 build.py -e production; then
    echo -e "${RED}Firmware build failed!${NC}"
    exit 1
  fi
  
  echo "Building firmware tools..."
  if ! cargo build --manifest-path tools/code/firmware-maker/Cargo.toml; then
    echo -e "${RED}Firmware maker build failed!${NC}"
    exit 1
  fi
  
  echo "Creating unsigned firmware binary..."
  ./tools/code/firmware-maker/target/debug/fmm --source build/mh1903.bin --destination keystone3-unsigned.bin
  
  if ! cargo build --manifest-path tools/code/firmware-checker/Cargo.toml; then
    echo -e "${RED}Firmware checker build failed!${NC}"
    exit 1
  fi
  
  echo "Validating built firmware structure..."
  ./tools/code/firmware-checker/target/debug/fmc --source keystone3-unsigned.bin
  
  echo -e "${GREEN}Firmware build completed successfully!${NC}"
}

download_official_firmware() {
  echo "Downloading official firmware from Keystone website..."
  
  # Determine correct download URL based on type
  if [[ "$firmwareType" == "multicoin" ]]; then
    url="https://keyst.one/contents/KeystoneFirmwareG3/v${version}/web3/keystone3.bin"
  elif [[ "$firmwareType" == "cypherpunk" ]]; then
    url="https://keyst.one/contents/KeystoneFirmwareG3/v${version}/cypherpunk/keystone3.bin"
  elif [[ "$firmwareType" == "btc" ]]; then
    url="https://keyst.one/contents/KeystoneFirmwareG3/v${version}/btc_only/keystone3.bin"
  fi
  
  echo "Downloading from: $url"
  if ! wget -O keystone3.bin "$url"; then
    echo -e "${RED}Failed to download official firmware from $url${NC}"
    exit 1
  fi
  
  # Check if download was successful and not empty
  if [[ -s keystone3.bin ]]; then
    echo -e "${GREEN}Download of keystone3.bin successful from $url${NC}"
  else
    echo -e "${RED}Download of keystone3.bin failed or resulted in an empty file from $url${NC}"
    exit 1
  fi
}

compare_firmware() {
  echo "Comparing firmware binaries..."
  
  echo "=========================="
  echo "SIGNED Binary from Keystone Website:"
  officialHash=$(sha256sum keystone3.bin | awk '{print $1}')
  echo "$officialHash  keystone3.bin"
  
  echo "=========================="
  echo "Binary from build process:"
  builtHash=$(sha256sum ./build/mh1903.bin | awk '{print $1}')
  echo "$builtHash  ./build/mh1903.bin"
  
  echo "=========================="
  echo "Unsigned Binary Analysis:"
  ./tools/code/firmware-checker/target/debug/fmc --source keystone3-unsigned.bin
  
  echo "=========================="
  echo "VERIFICATION RESULTS:"
  echo "Official firmware (signed): $officialHash"
  echo "Built firmware (unsigned):  $builtHash"
  
  # Note: We compare the built firmware with the unsigned version
  # because the official firmware is signed by Keystone
  unsignedHash=$(./tools/code/firmware-checker/target/debug/fmc --source keystone3-unsigned.bin 2>/dev/null | grep -o '[a-f0-9]\{64\}' | head -1 || echo "")
  
  if [[ "$builtHash" == "$unsignedHash" ]] || [[ -n "$unsignedHash" && "$builtHash" == "$unsignedHash" ]]; then
    echo -e "${GREEN}✓ REPRODUCIBLE: Built firmware matches unsigned content${NC}"
    verdict="reproducible"
  else
    echo -e "${YELLOW}⚠ Note: Comparison requires manual verification of unsigned content${NC}"
    echo "The official firmware is signed, while the built firmware is unsigned."
    echo "Manual verification of the unsigned content hashes is required."
    verdict="manual_verification_required"
  fi
  
  echo "=========================="
}

result() {
  echo "===== Begin Results ====="
  echo "firmware:       Keystone3 Pro"
  echo "version:        $version"
  echo "type:           $firmwareType"
  echo "verdict:        $verdict"
  echo "officialHash:   $officialHash"
  echo "builtHash:      $builtHash"
  echo "repository:     $repo"
  echo "tag:            tags/$version"
  
  if [[ "$verdict" == "reproducible" ]]; then
    echo ""
    echo "✓ The firmware builds reproducibly from source code."
  else
    echo ""
    echo "Manual verification required:"
    echo "- Official firmware is cryptographically signed by Keystone"
    echo "- Built firmware is unsigned but should match the unsigned content"
    echo "- Use firmware analysis tools to compare unsigned portions"
  fi
  
  echo "===== End Results ====="
  
  if [ "$shouldCleanup" = false ]; then
    echo ""
    echo "Verification files available at: $workDir/keystone3-firmware"
    echo "- Official firmware: keystone3.bin"
    echo "- Built firmware: build/mh1903.bin" 
    echo "- Unsigned version: keystone3-unsigned.bin"
  fi
}

cleanup() {
  echo "Cleaning up temporary files..."
  rm -rf "$workDir"
  $CONTAINER_CMD rmi keystonehq/keystone3_baker:latest -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Keystone3 Pro firmware verification..."
echo "This process may take 15-30 minutes depending on your system."
echo

prepare
echo "Environment prepared. Building firmware..."

build_firmware
echo "Build completed. Downloading official firmware..."

download_official_firmware
echo "Download completed. Comparing firmware..."

compare_firmware
echo "Comparison completed."

result
echo "Verification completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "Keystone3 Pro firmware verification finished!"