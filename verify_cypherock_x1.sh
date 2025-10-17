#!/bin/bash
# verify_cypherock_x1.sh v1.0.0 - Standalone verification script for Cypherock X1 Hardware Wallet
# Usage: verify_cypherock_x1.sh -v version [-c]

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
workDir="/tmp/cypherock-x1-verification"

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
else
    echo "Error: Neither docker nor podman found. Please install Docker or Podman."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Cypherock X1 constants
IMAGE_NAME="cypherock-x1-verifier"

# Create the actual Cypherock Dockerfile
create_dockerfile() {
  echo "Creating Dockerfile for Cypherock X1 verification..."
  cat > cypherock_x1.dockerfile << 'EOF'
# cypherockX1.dockerfile

# Base image with necessary build tools
FROM cypherock/x1-firmware-builder:v0.0.0

# Set the version tag as a build argument
ARG VERSION_TAG
ENV VERSION_TAG=${VERSION_TAG}

# Working directory within the container
WORKDIR /workspace

# Clone the repository, build the firmware, and perform verification
RUN set -e && \
    echo "Cloning repository..." && \
    if [ -d "x1_wallet_firmware" ]; then \
      echo "Removing existing x1_wallet_firmware directory..."; \
      rm -rf x1_wallet_firmware; \
    fi && \
    git clone --branch ${VERSION_TAG} --depth 1 https://github.com/Cypherock/x1_wallet_firmware.git --recurse-submodules && \
    cd x1_wallet_firmware && \
    mkdir -p build && cd build && \
    echo "Building firmware..." && \
    cmake -DCMAKE_BUILD_TYPE="Release" -DFIRMWARE_TYPE="Main" -DCMAKE_BUILD_PLATFORM="Device" -G "Ninja" .. && \
    ninja && \
    echo "Calculating SHA256 checksums for built binary..." && \
    sha256sum Cypherock-Main.bin > ../build_checksum.txt && \
    cd .. && \
    echo "Downloading released firmware binary from GitHub..." && \
    wget -O Cypherock-Main-released.bin "https://github.com/Cypherock/x1_wallet_firmware/releases/download/${VERSION_TAG}/Cypherock-Main.bin" && \
    echo "Calculating SHA256 checksums..." && \
    sha256sum Cypherock-Main-released.bin > release_checksum.txt && \
    echo "Compare built and released binaries..." && \
    cat build_checksum.txt && \
    cat release_checksum.txt

# Default command that outputs the verification results
CMD ["/bin/bash", "-c", "cd /workspace/x1_wallet_firmware && echo '===== CYPHEROCK X1 VERIFICATION RESULTS =====' && echo 'Built firmware:' && cat build_checksum.txt && echo 'Released firmware:' && cat release_checksum.txt && if cmp -s <(awk '{print $1}' build_checksum.txt) <(awk '{print $1}' release_checksum.txt); then echo 'VERDICT: REPRODUCIBLE - Firmware hashes match'; else echo 'VERDICT: NOT REPRODUCIBLE - Firmware hashes differ'; fi && echo '===== END RESULTS ====='"]
EOF
}

usage() {
  echo 'NAME
       verify_cypherock_x1.sh - verify Cypherock X1 hardware wallet firmware

SYNOPSIS
       verify_cypherock_x1.sh -v version [-c]

DESCRIPTION
       This command tries to verify firmware builds of Cypherock X1 hardware wallet.

       -v|--version The firmware version to verify (e.g., 0.6.2816)
       -c|--cleanup Clean up temporary files after testing

EXAMPLES
       verify_cypherock_x1.sh -v 0.6.2816
       verify_cypherock_x1.sh -v 0.6.2816 -c'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -v|--version) version="$2"; shift ;;
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

echo
echo "Verifying Cypherock X1 firmware version $version"
echo

prepare() {
  echo "Setting up verification environment..."
  
  # cleanup any existing work
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  # Set version tag
  VERSION_TAG="v$version"
  
  echo "Using version tag: $VERSION_TAG"
}

cleanup_images() {
  echo "Cleaning up old Docker images..."
  # Remove any existing images with the same name to force a fresh build
  $CONTAINER_CMD image rm -f $IMAGE_NAME 2>/dev/null || true
}

build_and_verify() {
  echo "Starting Cypherock X1 firmware verification..."
  
  # Create the Dockerfile
  create_dockerfile
  
  # Cleanup old images
  cleanup_images
  
  echo "Building Docker image for Cypherock X1 verification..."
  echo "This may take 10-20 minutes as it builds firmware from source..."
  
  # Build the Docker image
  if ! $CONTAINER_CMD build -t $IMAGE_NAME --build-arg VERSION_TAG="v$version" -f cypherock_x1.dockerfile .; then
    echo -e "${RED}Docker build failed!${NC}"
    echo "This may be due to:"
    echo "- Missing Cypherock base image (cypherock/x1-firmware-builder:v0.0.0)"
    echo "- Network issues downloading dependencies"
    echo "- Invalid version tag"
    exit 1
  fi
  
  echo "Running container to perform firmware verification..."
  
  # Run the container to perform verification and capture output
  echo "Comparing built firmware with official release..."
  verification_output=$($CONTAINER_CMD run --rm $IMAGE_NAME 2>&1)
  
  echo "$verification_output"
  
  # Extract verdict from output
  if echo "$verification_output" | grep -q "VERDICT: REPRODUCIBLE"; then
    verdict="reproducible"
    echo -e "${GREEN}✓ REPRODUCIBLE: Firmware builds identically from source${NC}"
  elif echo "$verification_output" | grep -q "VERDICT: NOT REPRODUCIBLE"; then
    verdict="not_reproducible"
    echo -e "${RED}✗ NOT REPRODUCIBLE: Firmware differs from official release${NC}"
  else
    verdict="verification_failed"
    echo -e "${RED}Verification failed - unable to determine result${NC}"
  fi
  
  # Extract hashes if available
  built_hash=$(echo "$verification_output" | grep "Built firmware:" -A1 | tail -n1 | awk '{print $1}' || echo "unknown")
  released_hash=$(echo "$verification_output" | grep "Released firmware:" -A1 | tail -n1 | awk '{print $1}' || echo "unknown")
}

result() {
  echo "===== Begin Results ====="
  echo "firmware:       Cypherock X1"
  echo "version:        $version"
  echo "verdict:        $verdict"
  echo "builtHash:      $built_hash"
  echo "releasedHash:   $released_hash"
  echo "repository:     https://github.com/Cypherock/x1_wallet_firmware.git"
  echo "tag:            v$version"
  echo ""
  if [[ "$verdict" == "reproducible" ]]; then
    echo "✓ The firmware builds reproducibly from source code."
  elif [[ "$verdict" == "not_reproducible" ]]; then
    echo "✗ The firmware does not build reproducibly."
  else
    echo "⚠ Verification process encountered issues."
  fi
  echo "===== End Results ====="
  
  if [ "$shouldCleanup" = false ]; then
    echo ""
    echo "Verification files available at: $workDir"
  fi
}

cleanup() {
  echo "Cleaning up temporary files..."
  rm -rf "$workDir"
  $CONTAINER_CMD rmi $IMAGE_NAME -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Cypherock X1 firmware verification..."
echo "This process may take 15-30 minutes depending on your system."
echo

prepare
echo "Environment prepared. Starting verification..."

build_and_verify
echo "Verification completed."

result
echo "Process completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "Cypherock X1 firmware verification finished!"