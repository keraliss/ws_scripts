#!/bin/bash
# passport_build.sh v2.0.0 - Standardized verification script for Passport Hardware Wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: passport_build.sh --version VERSION --type TYPE

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
workDir="$(pwd)/passport-work"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"

# Detect container runtime
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman" 
    echo "Using Podman for containerization"
else
    echo -e "${RED}Error: Neither docker nor podman found. Please install Docker or Podman.${NC}"
    exit 1
fi

# Color constants
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

# Passport constants
dockerImage="foundation-devices/passport2:latest"
verdict=""
exit_code=1

usage() {
    echo 'NAME
       passport_build.sh - verify Passport hardware wallet firmware

SYNOPSIS
       passport_build.sh --version VERSION --type TYPE

DESCRIPTION
       This command verifies firmware builds of Passport hardware wallet.
       Follows the WalletScrutiny standardized verification script format.

       --version   Firmware version (e.g., "2.4.0")
       --type      Screen type: color or mono

EXAMPLES
       passport_build.sh --version 2.4.0 --type color
       passport_build.sh --version 2.4.0 --type mono'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2"; shift ;;
    --type) screen="$2"; shift ;;
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

if [ -z "$screen" ]; then
  echo "Error: Screen type is required!"
  echo
  usage
  exit 1
fi

# Validate screen parameter
if [[ "$screen" != "color" && "$screen" != "mono" ]]; then
    echo -e "${RED}Error: Screen must be 'color' or 'mono', got: $screen${NC}"
    exit 1
fi

echo
echo "Verifying Passport firmware version $version ($screen)"
echo

prepare() {
    echo "Setting up Passport firmware verification..."
    
    # Set file name according to model specified
    if [[ "$screen" == "color" ]]; then
        fileName="v${version}-passport.bin"
    elif [[ "$screen" == "mono" ]]; then
        fileName="v${version}-founders-passport.bin"
    fi
    
    gitRevision="v$version"
    
    echo "Firmware version: $version"
    echo "Screen type: $screen"
    echo "Firmware file: $fileName"
    echo "Git revision: $gitRevision"
    
    # Remove any previous build artifacts
    rm -rf "$workDir"
    $CONTAINER_CMD image rm "$dockerImage" >/dev/null 2>&1 || true
    
    # Prepare the directory for building Passport's firmware
    mkdir -p "$workDir"
    cd "$workDir"
    
    echo -e "${GREEN}Environment prepared${NC}"
}

build_firmware() {
    echo "Starting Passport firmware build..."
    
    cd "$workDir"
    
    # Get the specified firmware release binary
    echo "Downloading firmware binary..."
    if ! wget -q --show-progress "https://github.com/Foundation-Devices/passport2/releases/download/v${version}/${fileName}"; then
        echo -e "${RED}Error: Failed to download firmware binary${NC}"
        write_results "ftbfs" "" "false" ""
        exit 1
    fi
    
    # Clone the specified release branch
    echo "Cloning Passport repository..."
    if ! git clone https://github.com/Foundation-Devices/passport2.git; then
        echo -e "${RED}Error: Failed to clone repository${NC}"
        write_results "ftbfs" "" "false" ""
        exit 1
    fi
    
    cd passport2
    
    echo "Checking out revision: $gitRevision"
    if ! git checkout "$gitRevision"; then
        echo -e "${RED}Error: Failed to checkout revision $gitRevision${NC}"
        write_results "ftbfs" "" "false" ""
        exit 1
    fi
    
    # Build the Docker image used for building firmware reproducibly
    echo "Building Docker image for reproducible builds..."
    if ! $CONTAINER_CMD build --no-cache -t "$dockerImage" .; then
        echo -e "${RED}Error: Failed to build Docker image${NC}"
        write_results "ftbfs" "" "false" ""
        exit 1
    fi
    
    # Build mpy-cross within the Docker image
    echo "Building mpy-cross..."
    if ! $CONTAINER_CMD run --rm \
        --volume "$PWD":/workspace \
        --user $(id -u):$(id -g) \
        --workdir /workspace \
        --env MPY_CROSS="/workspace/mpy-cross/mpy-cross-docker" \
        "$dockerImage" \
        make -C mpy-cross PROG=mpy-cross-docker BUILD=build-docker; then
        echo -e "${RED}Error: Failed to build mpy-cross${NC}"
        write_results "ftbfs" "" "false" ""
        exit 1
    fi
    
    # Specify correct build flags for each model and build the appropriate firmware file
    echo "Building firmware for $screen model..."
    if [[ "$screen" == "color" ]]; then
        buildCommand=(make -C ports/stm32/ LV_CFLAGS='-DLV_COLOR_DEPTH=16 -DLV_COLOR_16_SWAP -DLV_TICK_CUSTOM=1 -DSCREEN_MODE_COLOR -DHAS_FUEL_GAUGE' BOARD=Passport SCREEN_MODE=COLOR FROZEN_MANIFEST='boards/Passport/manifest.py')
    elif [[ "$screen" == "mono" ]]; then
        buildCommand=(make -C ports/stm32/ LV_CFLAGS='-DLV_COLOR_DEPTH=16 -DLV_COLOR_16_SWAP -DLV_TICK_CUSTOM=1 -DSCREEN_MODE_MONO' BOARD=Passport SCREEN_MODE=MONO FROZEN_MANIFEST='boards/Passport/manifest.py')
    fi
    
    if ! $CONTAINER_CMD run --rm \
        --volume "$PWD":/workspace \
        --user $(id -u):$(id -g) \
        --workdir /workspace \
        --env MPY_CROSS="/workspace/mpy-cross/mpy-cross-docker" \
        "$dockerImage" \
        "${buildCommand[@]}"; then
        echo -e "${RED}Error: Failed to build firmware${NC}"
        write_results "ftbfs" "" "false" ""
        exit 1
    fi
    
    echo -e "${GREEN}Firmware build completed successfully${NC}"
}

compare_firmware() {
    echo "Analyzing verification results..."
    
    cd "$workDir/passport2"
    
    # Get hashes
    buildHashActual=$(sha256sum ports/stm32/build-Passport/firmware-${screen^^}.bin | cut -d' ' -f1)
    releaseHashActual=$(sha256sum "../${fileName}" | cut -d' ' -f1)
    
    echo ""
    echo "============================================================"
    echo "Built v${version} binary sha256 hash:"
    echo "$buildHashActual"
    
    echo ""
    echo "v${version} release binary sha256 hash:"
    echo "$releaseHashActual"
    
    # Verify stripped release binary matches built binary
    echo ""
    echo "Comparing v${version} stripped release binary hash:"
    echo "Strip first 2048 bytes (header, signatures, zeroed bytes)"
    
    # Strip first 2048 bytes from release binary
    dd if="../${fileName}" of="no-header-${fileName}" ibs=2048 skip=1 status=none
    
    # Get hash of built firmware
    builtFirmwareHash=$(sha256sum ports/stm32/build-Passport/firmware-${screen^^}.bin | cut -d' ' -f1)
    strippedReleaseHash=$(sha256sum "no-header-${fileName}" | cut -d' ' -f1)
    
    echo "Expected v${version} build hash:"
    echo "$builtFirmwareHash"
    echo ""
    echo "Stripped release hash:"
    echo "$strippedReleaseHash"
    echo ""
    
    # Compare stripped release with built firmware
    if [[ "$builtFirmwareHash" == "$strippedReleaseHash" ]]; then
        echo -e "${GREEN}✓ REPRODUCIBLE: Stripped firmware matches built firmware${NC}"
        echo "============================================================"
        verdict="reproducible"
        exit_code=0
    else
        echo -e "${RED}✗ NOT REPRODUCIBLE: Firmware hashes differ${NC}"
        echo "============================================================"
        verdict="not_reproducible"
        exit_code=1
    fi
    
    write_results "$verdict" "$buildHashActual" "$([ $exit_code -eq 0 ] && echo 'true' || echo 'false')" "$strippedReleaseHash"
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
  - architecture: arm-cortex-m7
    firmware_type: ${screen}
    files:
      - filename: v${version}-${screen}-passport.bin
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
    echo "firmware:        Passport"
    echo "version:         $version"
    echo "type:            $screen"
    echo "verdict:         $verdict"
    echo "builtHash:       ${buildHashActual:-N/A}"
    echo "releaseHash:     ${releaseHashActual:-N/A}"
    echo "strippedHash:    ${strippedReleaseHash:-N/A}"
    echo "repository:      https://github.com/Foundation-Devices/passport2"
    echo "tag:             $gitRevision"
    echo ""
    if [[ "$verdict" == "reproducible" ]]; then
        echo "✓ The firmware builds reproducibly from source code."
    else
        echo "✗ The firmware does not build reproducibly."
    fi
    echo "===== End Results ====="
    echo ""
    echo "Verification files available at: $workDir/passport2"
    echo "  - Built firmware: ports/stm32/build-Passport/firmware-${screen^^}.bin"
    echo "  - Downloaded firmware: ../${fileName}"
    echo "Results file: $RESULTS_FILE"
}

cleanup() {
    echo "Cleaning up Docker resources..."
    $CONTAINER_CMD image rm "$dockerImage" -f 2>/dev/null || true
    $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Passport firmware verification..."
echo "This process may take 15-30 minutes depending on your system."
echo

prepare
echo "Environment prepared. Building firmware..."

build_firmware
echo "Build completed. Comparing firmware..."

compare_firmware
echo "Comparison completed."

result
echo "Verification completed."

cleanup

echo
echo "Passport firmware verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."

exit $exit_code