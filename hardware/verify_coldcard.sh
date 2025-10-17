#!/bin/bash
# verify_coldcard.sh v1.0.0 - Standalone verification script for Coldcard Hardware Wallet
# Usage: verify_coldcard.sh -v version -m mk [-d custom_download] [-c]

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
workDir="/tmp/coldcard-verification"

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

# Coldcard constants
repo="https://github.com/Coldcard/firmware.git"

usage() {
  echo 'NAME
       verify_coldcard.sh - verify Coldcard hardware wallet firmware

SYNOPSIS
       verify_coldcard.sh -v version -m mk [-d custom_download] [-c]

DESCRIPTION
       This command tries to verify firmware builds of Coldcard hardware wallet.

       -v|--version Full version string (e.g., "2024-05-09T1527-v5.3.1")
       -m|--mk Hardware model: mk4 or q1
       -d|--download Custom download filename (optional)
       -c|--cleanup Clean up temporary files after testing

EXAMPLES
       verify_coldcard.sh -v "2024-05-09T1527-v5.3.1" -m mk4
       verify_coldcard.sh -v "2024-07-05T1349-v5.3.3" -m mk4 -d "2024-07-05T1348-v5.3.3-mk4-coldcard.dfu"
       verify_coldcard.sh -v "2024-05-09T1527-v5.3.1" -m q1 -c'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -v|--version) version="$2"; shift ;;
    -m|--mk) mk="$2"; shift ;;
    -d|--download) custom_download="$2"; shift ;;
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

if [ -z "$mk" ]; then
  echo "Error: Hardware model (mk) is required!"
  echo
  usage
  exit 1
fi

# Validate hardware model
if [[ "$mk" != "mk4" && "$mk" != "q1" ]]; then
  echo "Error: Invalid hardware model '$mk'. Must be: mk4 or q1"
  exit 1
fi

echo
echo "Verifying Coldcard $mk firmware version $version"
echo

prepare() {
  echo "Setting up verification environment..."
  
  # Set up filenames and parameters
  dfu_filename="${version}-${mk}-coldcard.dfu"
  
  if [[ -z "$custom_download" ]]; then
    PUBLISHED_BIN="$dfu_filename"
  else
    PUBLISHED_BIN="$custom_download"
  fi
  
  # Set hardware-specific parameters
  if [[ $mk == 'mk4' ]]; then
    privileges="--privileged"
    mkfile="MK4-Makefile"
  elif [[ $mk == 'q1' ]]; then
    privileges="--privileged"
    mkfile="Q1-Makefile"
  fi
  
  # Extract short version
  short_version=$(echo $version | grep -Po 'v\K[^-]*')
  
  # cleanup any existing work
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  echo "Cloning Coldcard firmware repository..."
  git clone $repo firmware
  cd firmware
  
  echo "Checking out version tag: $version"
  TAG=$(basename $version | cut -d "-" -f1,2,3,4)
  SOURCE_DATE_EPOCH=$(git show -s --format=%at $TAG | tail -n1)
  git checkout ${version}
}

download_firmware() {
  echo "Downloading official firmware from Coldcard website..."
  
  cd releases
  # Download firmware, renaming if custom download name is provided
  echo "Downloading: https://coldcard.com/downloads/$PUBLISHED_BIN"
  if ! wget -O "$dfu_filename" "https://coldcard.com/downloads/$PUBLISHED_BIN"; then
    echo -e "${RED}Failed to download official firmware${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Official firmware downloaded successfully${NC}"
  cd ..
}

build_firmware() {
  echo "Building Coldcard firmware..."
  
  echo "Building Docker image for Coldcard build environment..."
  cd stm32
  if ! $CONTAINER_CMD build -t coldcard-build - < dockerfile.build; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  echo "Running firmware build in container..."
  cd ..
  if ! $CONTAINER_CMD run \
    --volume $(realpath .):/work/src:ro \
    --volume $(realpath stm32/built):/work/built:rw ${privileges} \
    coldcard-build \
    sh -c "sh src/stm32/repro-build.sh ${short_version} ${mk} ${mkfile}"; then
    echo -e "${RED}Firmware build failed!${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Firmware build completed successfully!${NC}"
}

compare_firmware() {
  echo "Comparing firmware binaries..."
  
  # Remove signatures and compare hashes
  echo "Removing signatures for comparison..."
  xxd stm32/built/firmware-signed.bin | sed -e 's/^00003f[89abcdef]0: .*/(firmware signature here)/' | xxd -r > firmware-nosig.bin
  xxd stm32/built/check-fw.bin | sed -e 's/^00003f[89abcdef]0: .*/(firmware signature here)/' | xxd -r > ${version}-${mk}-nosig.bin
  
  echo ""
  echo "=========================="
  echo "Hash of non-signature parts downloaded/compiled:"
  officialHashUnsigned=$(sha256sum *-v${short_version}-${mk}-nosig.bin | awk '{print $1}')
  builtHashUnsigned=$(sha256sum firmware-nosig.bin | awk '{print $1}')
  echo "${officialHashUnsigned}  ${version}-${mk}-nosig.bin"
  echo "${builtHashUnsigned}  firmware-nosig.bin"
  
  echo ""
  echo "=========================="
  echo "Hash of the signed firmware:"
  officialHashSigned=$(sha256sum releases/$dfu_filename | awk '{print $1}')
  builtHashSigned=$(sha256sum stm32/built/firmware-signed.dfu | awk '{print $1}')
  echo "${officialHashSigned}  releases/${dfu_filename}"
  echo "${builtHashSigned}  stm32/built/firmware-signed.dfu"
  
  echo ""
  echo "=========================="
  echo "VERIFICATION RESULTS:"
  echo "Official firmware (signed):   $officialHashSigned"
  echo "Built firmware (signed):      $builtHashSigned"
  echo "Official firmware (unsigned): $officialHashUnsigned"
  echo "Built firmware (unsigned):    $builtHashUnsigned"
  
  if [[ "$builtHashUnsigned" == "$officialHashUnsigned" ]]; then
    echo -e "${GREEN}✓ REPRODUCIBLE: Built firmware matches unsigned content${NC}"
    verdict="reproducible"
  else
    echo -e "${RED}✗ NOT REPRODUCIBLE: Unsigned firmware differs${NC}"
    verdict="not_reproducible"
  fi
  
  echo "=========================="
}

result() {
  echo "===== Begin Results ====="
  echo "firmware:       Coldcard $mk"
  echo "version:        $version"
  echo "model:          $mk"
  echo "verdict:        $verdict"
  echo "officialHashSigned:   $officialHashSigned"
  echo "builtHashSigned:      $builtHashSigned"
  echo "officialHashUnsigned: $officialHashUnsigned"
  echo "builtHashUnsigned:    $builtHashUnsigned"
  echo "repository:     $repo"
  echo "tag:            $version"
  
  if [[ "$verdict" == "reproducible" ]]; then
    echo ""
    echo "✓ The firmware builds reproducibly from source code."
  else
    echo ""
    echo "✗ The firmware does not build reproducibly."
  fi
  
  echo "===== End Results ====="
  
  if [ "$shouldCleanup" = false ]; then
    echo ""
    echo "Verification files available at: $workDir/firmware"
    echo "- Official firmware: releases/$dfu_filename"
    echo "- Built firmware: stm32/built/firmware-signed.dfu" 
    echo "- Unsigned comparison files: *-nosig.bin"
  fi
}

cleanup() {
  echo "Cleaning up temporary files..."
  rm -rf "$workDir"
  $CONTAINER_CMD rmi coldcard-build -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Coldcard firmware verification..."
echo "This process may take 10-20 minutes depending on your system."
echo

prepare
echo "Environment prepared. Downloading official firmware..."

download_firmware
echo "Download completed. Building firmware from source..."

build_firmware
echo "Build completed. Comparing firmware..."

compare_firmware
echo "Comparison completed."

result
echo "Verification completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "Coldcard firmware verification finished!"