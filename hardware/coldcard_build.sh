#!/bin/bash
# coldcard_build.sh v2.0.0 - Standardized verification script for Coldcard Hardware Wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: coldcard_build.sh --version VERSION --type MODEL [--apk FIRMWARE_FILE]

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

# Global Variables
SCRIPT_VERSION="v2.0.0"
BUILD_TYPE="firmware"
workDir="$(pwd)/coldcard-work"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
custom_firmware=""

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
verdict=""
exit_code=1

usage() {
  echo 'NAME
       coldcard_build.sh - verify Coldcard hardware wallet firmware

SYNOPSIS
       coldcard_build.sh --version VERSION --type MODEL [--apk FIRMWARE_FILE]

DESCRIPTION
       This command verifies firmware builds of Coldcard hardware wallet.
       Follows the WalletScrutiny standardized verification script format.

       --version   Firmware version (e.g., "5.4.4" or "1.3.4Q")
       --type      Hardware model: mk4 or q1
       --apk       Optional firmware file provided by user instead of downloading

EXAMPLES
       coldcard_build.sh --version "5.4.4" --type mk4
       coldcard_build.sh --version "1.3.4Q" --type q1
       coldcard_build.sh --version "5.4.4" --type mk4 --apk /path/to/firmware.dfu'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2"; shift ;;
    --type) model="$2"; shift ;;
    --apk) custom_firmware="$2"; shift ;;
    --help) usage; exit 0 ;;
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

if [ -z "$model" ]; then
  echo "Error: Hardware model (type) is required!"
  echo
  usage
  exit 1
fi

# Validate hardware model
if [[ "$model" != "mk4" && "$model" != "q1" ]]; then
  echo "Error: Invalid hardware model '$model'. Must be: mk4 or q1"
  exit 1
fi

# Construct full version string based on model and version
if [[ "$model" == "q1" ]]; then
    # Q1 versions need the Q suffix if not present
    # But don't add Q if version already has Q in it (like QX)
    if [[ ! "$version" =~ Q ]]; then
        version="${version}Q"
    fi
fi

echo
echo "Verifying Coldcard $model firmware version $version"
echo

prepare() {
  echo "Setting up verification environment..."
  
  # cleanup any existing work
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  echo "Cloning Coldcard firmware repository..."
  git clone $repo firmware
  cd firmware
  
  # Find matching tag for the version
  if [[ "$model" == "q1" ]]; then
      full_version_tag=$(git tag | grep -E ".*-v${version}$" | head -1)
  else
      full_version_tag=$(git tag | grep -E ".*-v${version}$" | head -1)
  fi
  
  if [ -z "$full_version_tag" ]; then
    echo "Error: Could not find version tag for $version"
    echo "Available tags:"
    git tag | grep -E "v${version}" | head -10
    write_results "ftbfs" "" "false" ""
    exit 1
  fi
  
  echo "Found version tag: $full_version_tag"
  
  # Set up filenames and parameters
  dfu_filename="${full_version_tag}-${model}-coldcard.dfu"
  
  if [[ -n "$custom_firmware" ]]; then
    if [ ! -f "$custom_firmware" ]; then
      echo "Error: Custom firmware file not found: $custom_firmware"
      write_results "ftbfs" "" "false" ""
      exit 1
    fi
    PUBLISHED_BIN=$(basename "$custom_firmware")
    echo "Using custom firmware file: $custom_firmware"
  else
    PUBLISHED_BIN="$dfu_filename"
  fi
  
  # Set hardware-specific parameters
  if [[ $model == 'mk4' ]]; then
    privileges="--privileged"
    mkfile="MK4-Makefile"
  elif [[ $model == 'q1' ]]; then
    privileges="--privileged"
    mkfile="Q1-Makefile"
  fi
  
  # Extract short version for build system
  short_version=$(echo $full_version_tag | grep -Po 'v\K[^-]*')
  
  echo "Checking out version tag: $full_version_tag"
  TAG=$(basename $full_version_tag | cut -d "-" -f1,2,3,4)
  SOURCE_DATE_EPOCH=$(git show -s --format=%at $TAG | tail -n1)
  git checkout ${full_version_tag}
  
  # Store the full version for later use
  export FULL_VERSION_TAG="$full_version_tag"
  export SHORT_VERSION="$short_version"
  
  echo -e "${GREEN}Environment prepared${NC}"
}

download_firmware() {
  echo "Downloading official firmware from Coldcard website..."
  
  cd "$workDir/firmware/releases"
  
  if [[ -n "$custom_firmware" ]]; then
    echo "Copying custom firmware file..."
    cp "$custom_firmware" "$dfu_filename"
  else
    # Download firmware
    echo "Downloading: https://coldcard.com/downloads/$PUBLISHED_BIN"
    if ! wget -O "$dfu_filename" "https://coldcard.com/downloads/$PUBLISHED_BIN"; then
      echo -e "${RED}Failed to download official firmware${NC}"
      write_results "ftbfs" "" "false" ""
      exit 1
    fi
  fi
  
  echo -e "${GREEN}Official firmware downloaded${NC}"
  cd "$workDir/firmware"
}

build_firmware() {
  echo "Building Coldcard firmware..."
  
  cd "$workDir/firmware"
  
  echo "Building Docker image for Coldcard build environment..."
  cd stm32
  if ! $CONTAINER_CMD build -t coldcard-build - < dockerfile.build; then
    echo -e "${RED}Docker build failed!${NC}"
    write_results "ftbfs" "" "false" ""
    exit 1
  fi
  
  echo "Running firmware build in container..."
  cd "$workDir/firmware"
  if ! $CONTAINER_CMD run \
    --volume $(realpath .):/work/src:ro \
    --volume $(realpath stm32/built):/work/built:rw ${privileges} \
    coldcard-build \
    sh -c "sh src/stm32/repro-build.sh ${SHORT_VERSION} ${model} ${mkfile}"; then
    echo -e "${RED}Firmware build failed!${NC}"
    write_results "ftbfs" "" "false" ""
    exit 1
  fi
  
  echo -e "${GREEN}Firmware build completed successfully!${NC}"
}

compare_firmware() {
  echo "Comparing firmware binaries..."
  
  cd "$workDir/firmware"
  
  # Remove signatures and compare hashes
  echo "Removing signatures for comparison..."
  xxd stm32/built/firmware-signed.bin | sed -e 's/^00003f[89abcdef]0: .*/(firmware signature here)/' | xxd -r > firmware-nosig.bin
  xxd stm32/built/check-fw.bin | sed -e 's/^00003f[89abcdef]0: .*/(firmware signature here)/' | xxd -r > ${FULL_VERSION_TAG}-${model}-nosig.bin
  
  echo ""
  echo "============================================================"
  echo "Hash of non-signature parts downloaded/compiled:"
  officialHashUnsigned=$(sha256sum *-v${SHORT_VERSION}*-${model}-nosig.bin | awk '{print $1}')
  builtHashUnsigned=$(sha256sum firmware-nosig.bin | awk '{print $1}')
  echo "${officialHashUnsigned}  ${FULL_VERSION_TAG}-${model}-nosig.bin"
  echo "${builtHashUnsigned}  firmware-nosig.bin"
  
  echo ""
  echo "Hash of the signed firmware:"
  officialHashSigned=$(sha256sum releases/$dfu_filename | awk '{print $1}')
  builtHashSigned=$(sha256sum stm32/built/firmware-signed.dfu | awk '{print $1}')
  echo "${officialHashSigned}  releases/${dfu_filename}"
  echo "${builtHashSigned}  stm32/built/firmware-signed.dfu"
  
  echo ""
  echo "VERIFICATION RESULTS:"
  echo "Official firmware (signed):   $officialHashSigned"
  echo "Built firmware (signed):      $builtHashSigned"
  echo "Official firmware (unsigned): $officialHashUnsigned"
  echo "Built firmware (unsigned):    $builtHashUnsigned"
  echo ""
  
  if [[ "$builtHashUnsigned" == "$officialHashUnsigned" ]]; then
    verdict="reproducible"
    echo -e "${GREEN}✓ REPRODUCIBLE: Built firmware matches unsigned content${NC}"
    echo "============================================================"
    exit_code=0
  else
    verdict="not_reproducible"
    echo -e "${RED}✗ NOT REPRODUCIBLE: Unsigned firmware differs${NC}"
    echo "============================================================"
    exit_code=1
  fi
  
  write_results "$verdict" "$builtHashUnsigned" "$([ $exit_code -eq 0 ] && echo 'true' || echo 'false')" "$officialHashUnsigned"
}

write_results() {
  local status=$1
  local hash=$2
  local match=$3
  local expected_hash=$4
  
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+0000")
  
  local arch=""
  if [[ "$model" == "mk4" ]]; then
    arch="arm-cortex-m4"
  elif [[ "$model" == "q1" ]]; then
    arch="arm-cortex-m7"
  fi
  
  cat > "$RESULTS_FILE" << EOF
date: ${timestamp}
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: ${arch}
    firmware_type: ${model}
    files:
      - filename: ${FULL_VERSION_TAG:-$version}-${model}-coldcard.dfu
        hash: ${hash}
        match: ${match}
        expected_hash: ${expected_hash}
        status: ${status}
EOF

  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

result() {
  echo ""
  echo "===== Begin Results ====="
  echo "firmware:       Coldcard $model"
  echo "version:        $version"
  echo "type:           $model"
  echo "verdict:        $verdict"
  echo "officialHashSigned:   ${officialHashSigned:-N/A}"
  echo "builtHashSigned:      ${builtHashSigned:-N/A}"
  echo "officialHashUnsigned: ${officialHashUnsigned:-N/A}"
  echo "builtHashUnsigned:    ${builtHashUnsigned:-N/A}"
  echo "repository:     $repo"
  echo "tag:            ${FULL_VERSION_TAG:-N/A}"
  echo ""
  if [[ "$verdict" == "reproducible" ]]; then
    echo "✓ The firmware builds reproducibly from source code."
  else
    echo "✗ The firmware does not build reproducibly."
  fi
  echo "===== End Results ====="
  echo ""
  echo "Verification files available at: $workDir/firmware"
  echo "  - Official firmware: releases/$dfu_filename"
  echo "  - Built firmware: stm32/built/firmware-signed.dfu"
  echo "Results file: $RESULTS_FILE"
}

cleanup() {
  echo "Cleaning up Docker resources..."
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

cleanup

echo
echo "Coldcard firmware verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."

exit $exit_code