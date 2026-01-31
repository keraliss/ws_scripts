#!/bin/bash
# bitbox02_build.sh v2.0.0 - Standardized verification script for BitBox02 Hardware Wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: bitbox02_build.sh --version VERSION [--type TYPE]

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
workDir="$(pwd)/bitbox02-work"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"

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

# BitBox02 constants
firmwareType="btc"  # Default to BTC-only
verdict=""
exit_code=1

usage() {
  echo 'NAME
       bitbox02_build.sh - verify BitBox02 hardware wallet firmware

SYNOPSIS
       bitbox02_build.sh --version VERSION [--type TYPE]

DESCRIPTION
       This command verifies firmware builds of BitBox02 hardware wallet.
       Follows the WalletScrutiny standardized verification script format.

       --version   Firmware version (e.g., "9.23.2")
       --type      Firmware type: btc|multi (default: btc)

EXAMPLES
       bitbox02_build.sh --version 9.23.2
       bitbox02_build.sh --version 9.23.2 --type multi'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2"; shift ;;
    --type) firmwareType="$2"; shift ;;
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

# Validate firmware type
if [[ "$firmwareType" != "btc" && "$firmwareType" != "multi" ]]; then
  echo "Error: Invalid firmware type '$firmwareType'. Must be: btc or multi"
  exit 1
fi

echo
echo "Verifying BitBox02 firmware version $version ($firmwareType)"
echo

prepare() {
  echo "Setting up verification environment..."
  
  # Detect system architecture
  ARCH=$(uname -m)
  echo "System Architecture: $ARCH"
  
  # Set up version strings based on firmware type
  if [[ "$firmwareType" == "btc" ]]; then
    VERSION="firmware-btc-only/v${version}"
    MAKE_COMMAND="make firmware-btc"
    FIRMWARE_RELEASE_PATH="firmware-btc-only"
    FIRMWARE_PREFIX="firmware-btc"
    BUILT_FIRMWARE_PATH="build/bin/firmware-btc.bin"
    DOWNLOAD_URL="https://github.com/BitBoxSwiss/bitbox02-firmware/releases/download/${FIRMWARE_RELEASE_PATH}%2Fv${version}/firmware-bitbox02-btconly.v${version}.signed.bin"
    SIGNED_FILENAME="firmware-bitbox02-btconly.v${version}.signed.bin"
  else
    VERSION="firmware/v${version}"
    MAKE_COMMAND="make firmware"
    FIRMWARE_RELEASE_PATH="firmware"
    FIRMWARE_PREFIX="firmware"
    BUILT_FIRMWARE_PATH="build/bin/firmware.bin"
    DOWNLOAD_URL="https://github.com/BitBoxSwiss/bitbox02-firmware/releases/download/${FIRMWARE_RELEASE_PATH}%2Fv${version}/firmware-bitbox02-multi.v${version}.signed.bin"
    SIGNED_FILENAME="firmware-bitbox02-multi.v${version}.signed.bin"
  fi
  
  # cleanup any existing work
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  echo "Using version tag: $VERSION"
  echo "Make command: $MAKE_COMMAND"
  echo "Download URL: $DOWNLOAD_URL"
  echo -e "${GREEN}Environment prepared${NC}"
}

build_firmware() {
  echo "Cloning BitBox02 firmware repository..."
  
  cd "$workDir"
  
  MAX_RETRIES=3
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    if git clone --depth 1 --branch "$VERSION" --recurse-submodules https://github.com/BitBoxSwiss/bitbox02-firmware temp; then
      break
    fi
    retry_count=$((retry_count + 1))
    if [ $retry_count -eq $MAX_RETRIES ]; then
      echo -e "${RED}Failed to clone repository after $MAX_RETRIES attempts${NC}"
      write_results "ftbfs" "" "false" ""
      exit 1
    fi
    echo "Clone failed, retrying in 5 seconds..."
    sleep 5
  done
  
  cd temp
  
  # Fetch tags
  git fetch --tags
  
  # Apply version-specific patches if needed
  if [[ "$VERSION" == "firmware-btc-only/v9.15.0" || "$VERSION" == "firmware/v9.15.0" ]]; then
    echo "Applying patch for v9.15.0..."
    sed -i 's/RUN CARGO_HOME=\/opt\/cargo cargo install bindgen-cli --version 0.65.1/RUN CARGO_HOME=\/opt\/cargo cargo install bindgen-cli --version 0.65.1 --locked/' Dockerfile
  fi
  
  # Modify Dockerfile for explicit architecture
  echo "Configuring Dockerfile for architecture: $ARCH"
  case "$ARCH" in
    x86_64)
      sed -i 's|go1.19.3.linux-${TARGETARCH}|go1.19.3.linux-amd64|g' Dockerfile
      ;;
    aarch64|arm64)
      sed -i 's|go1.19.3.linux-${TARGETARCH}|go1.19.3.linux-arm64|g' Dockerfile
      ;;
    *)
      echo -e "${RED}Unsupported architecture: $ARCH${NC}"
      write_results "ftbfs" "" "false" ""
      exit 1
      ;;
  esac
  
  echo "Building Docker image for BitBox02 firmware..."
  if ! $CONTAINER_CMD build --pull --platform linux/amd64 --force-rm --no-cache -t bitbox02-firmware .; then
    echo -e "${RED}Docker build failed!${NC}"
    write_results "ftbfs" "" "false" ""
    exit 1
  fi
  
  # Revert local Dockerfile patch
  git checkout -- Dockerfile
  
  echo "Running firmware build command: $MAKE_COMMAND"
  if ! $CONTAINER_CMD run -it --rm --volume "$(pwd)":/bb02 bitbox02-firmware bash -c "git config --global --add safe.directory /bb02 && cd /bb02 && $MAKE_COMMAND"; then
    echo -e "${RED}Firmware build failed!${NC}"
    write_results "ftbfs" "" "false" ""
    exit 1
  fi
  
  echo -e "${GREEN}Firmware build completed successfully!${NC}"
}

download_and_compare() {
  echo "Downloading official signed BitBox02 firmware..."
  echo "URL: $DOWNLOAD_URL"
  
  cd "$workDir/temp"
  
  MAX_RETRIES=3
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    if wget -O "$SIGNED_FILENAME" "$DOWNLOAD_URL"; then
      break
    fi
    status=$?
    if [[ $status -eq 8 ]]; then
      echo -e "${YELLOW}Warning: Received HTTP 404 from ${DOWNLOAD_URL}${NC}" >&2
      
      # Try alternative naming patterns
      ALT_SIGNED_FILENAME="firmware-${firmwareType}.v${version}.signed.bin"
      ALT_DOWNLOAD_URL="https://github.com/BitBoxSwiss/bitbox02-firmware/releases/download/${FIRMWARE_RELEASE_PATH}%2Fv${version}/${ALT_SIGNED_FILENAME}"
      echo -e "${YELLOW}Trying alternative URL: ${ALT_DOWNLOAD_URL}${NC}" >&2
      
      if wget -O "$ALT_SIGNED_FILENAME" "$ALT_DOWNLOAD_URL"; then
        SIGNED_FILENAME="$ALT_SIGNED_FILENAME"
        break
      fi
    fi
    retry_count=$((retry_count + 1))
    if [ $retry_count -eq $MAX_RETRIES ]; then
      echo -e "${RED}Failed to download firmware after $MAX_RETRIES attempts${NC}" >&2
      write_results "ftbfs" "" "false" ""
      exit 1
    fi
    echo "Download failed, retrying in 5 seconds..."
    sleep 5
  done
  
  if [[ ! -s "$SIGNED_FILENAME" ]]; then
    echo -e "${RED}Error: Downloaded asset '$SIGNED_FILENAME' is missing or empty${NC}" >&2
    write_results "ftbfs" "" "false" ""
    exit 1
  fi
  
  echo "Calculating hashes..."
  
  # Calculate hash of signed download
  signedHash=$(sha256sum "$SIGNED_FILENAME" | awk '{print $1}')
  echo "Hash of signed download: $signedHash"
  
  # Calculate hash of built binary
  builtHash=$(sha256sum "$BUILT_FIRMWARE_PATH" | awk '{print $1}')
  echo "Hash of built binary: $builtHash"
  
  # Unpack signed binary (remove signature)
  echo "Unpacking signed binary..."
  head -c 588 "$SIGNED_FILENAME" > p_head.bin
  tail -c +589 "$SIGNED_FILENAME" > p_${FIRMWARE_PREFIX}.bin
  
  if [[ ! -s "p_${FIRMWARE_PREFIX}.bin" ]]; then
    echo -e "${RED}Error: Failed to extract unsigned payload from '$SIGNED_FILENAME'${NC}" >&2
    write_results "ftbfs" "" "false" ""
    exit 1
  fi
  
  downloadStrippedSigHash=$(sha256sum p_${FIRMWARE_PREFIX}.bin | awk '{print $1}')
  
  # Extract version and calculate device firmware hash
  cat p_head.bin | tail -c +$(( 8 + 6 * 64 + 1 )) | head -c 4 > p_version.bin
  firmwareBytesCount=$(wc -c p_${FIRMWARE_PREFIX}.bin | sed 's/ .*//g')
  maxFirmwareSize=884736
  paddingBytesCount=$(( maxFirmwareSize - firmwareBytesCount ))
  dd if=/dev/zero ibs=1 count=$paddingBytesCount 2>/dev/null | tr "\000" "\377" > p_padding.bin
  downloadFirmwareHash=$( cat p_version.bin p_${FIRMWARE_PREFIX}.bin p_padding.bin | sha256sum | cut -c1-64 | xxd -r -p | sha256sum | cut -c1-64 )
  
  echo ""
  echo "============================================================"
  echo "VERIFICATION RESULTS:"
  echo "Signed download:             $signedHash"
  echo "Signed download minus sig:   $downloadStrippedSigHash"
  echo "Built binary:                $builtHash"
  echo "Firmware as shown in device: $downloadFirmwareHash"
  echo "                            (double sha256 over version,"
  echo "                             firmware and padding)"
  echo ""
  
  # Determine verdict
  if [[ "$downloadStrippedSigHash" == "$builtHash" ]]; then
    verdict="reproducible"
    echo -e "${GREEN}✓ REPRODUCIBLE: Built firmware matches unsigned content${NC}"
    echo "============================================================"
    exit_code=0
  else
    verdict="not_reproducible"
    echo -e "${RED}✗ NOT REPRODUCIBLE: Firmware hashes differ${NC}"
    echo "============================================================"
    exit_code=1
  fi
  
  write_results "$verdict" "$builtHash" "$([ $exit_code -eq 0 ] && echo 'true' || echo 'false')" "$downloadStrippedSigHash"
}

write_results() {
  local status=$1
  local hash=$2
  local match=$3
  local expected_hash=$4
  
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+0000")
  
  cat > "$RESULTS_FILE" << EOF
date: ${timestamp}
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: arm-cortex-m4
    firmware_type: ${firmwareType}
    files:
      - filename: firmware-bitbox02-${firmwareType}.v${version}.signed.bin
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
  echo "firmware:       BitBox02"
  echo "version:        $version"
  echo "type:           $firmwareType"
  echo "verdict:        $verdict"
  echo "signedHash:     ${signedHash:-N/A}"
  echo "builtHash:      ${builtHash:-N/A}"
  echo "unsignedHash:   ${downloadStrippedSigHash:-N/A}"
  echo "deviceHash:     ${downloadFirmwareHash:-N/A}"
  echo "repository:     https://github.com/BitBoxSwiss/bitbox02-firmware"
  echo "tag:            $VERSION"
  echo ""
  if [[ "$verdict" == "reproducible" ]]; then
    echo "✓ The firmware builds reproducibly from source code."
  else
    echo "✗ The firmware does not build reproducibly."
  fi
  echo "===== End Results ====="
  echo ""
  echo "Verification files available at: $workDir/temp"
  echo "  - Built firmware: $BUILT_FIRMWARE_PATH"
  echo "  - Downloaded firmware: $SIGNED_FILENAME"
  echo "Results file: $RESULTS_FILE"
}

cleanup() {
  echo "Cleaning up Docker resources..."
  $CONTAINER_CMD rmi bitbox02-firmware -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting BitBox02 firmware verification..."
echo "This process may take 15-30 minutes depending on your system."
echo

prepare
echo "Environment prepared. Building firmware..."

build_firmware
echo "Build completed. Downloading and comparing..."

download_and_compare
echo "Comparison completed."

result
echo "Verification completed."

cleanup

echo
echo "BitBox02 firmware verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."

exit $exit_code