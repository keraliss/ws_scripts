#!/bin/bash
# verify_onekey_enhanced.sh v1.1.0 - Enhanced OneKey Hardware Wallet verification with diff analysis
# Usage: verify_onekey_enhanced.sh -t type -v version -h hash -d date [-c]

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
workDir="/tmp/onekey-verification"

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

# OneKey constants
repo="https://github.com/OneKeyHQ/firmware.git"
IMAGE_NAME="onekey-firmware-verifier"

usage() {
  echo 'NAME
       verify_onekey_enhanced.sh - verify OneKey hardware wallet firmware with diff analysis

SYNOPSIS
       verify_onekey_enhanced.sh -t type -v version -h hash -d date [-c]

DESCRIPTION
       This command tries to verify firmware builds of OneKey hardware wallets
       and provides detailed analysis when builds don'\''t match.
       
       -t, --type        Device type (mini, classic, touch)
       -v, --version     Firmware version (e.g., 3.11.0)
       -h, --hash        Short commit hash (e.g., 75f1721)
       -d, --date        Release date in MMDD format (e.g., 0908)
       -c, --cleanup     Clean up temporary files after verification

EXAMPLES
       verify_onekey_enhanced.sh -t classic -v 3.11.0 -h 75f1721 -d 0908
       verify_onekey_enhanced.sh -t mini -v 3.9.0 -h f3b0717 -d 0805 -c
       verify_onekey_enhanced.sh -t touch -v 4.0.0 -h abc1234 -d 1201'
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--type) type="$2"; shift ;;
    -v|--version) version="$2"; shift ;;
    -h|--hash) short_hash="$2"; shift ;;
    -d|--date) short_release_date="$2"; shift ;;
    -c|--cleanup) shouldCleanup=true ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Validate inputs
if [ -z "$type" ]; then
  echo "Error: Device type is required!"
  echo
  usage
  exit 1
fi

if [ -z "$version" ]; then
  echo "Error: Version is required!"
  echo
  usage
  exit 1
fi

if [ -z "$short_hash" ]; then
  echo "Error: Short hash is required!"
  echo
  usage
  exit 1
fi

if [ -z "$short_release_date" ]; then
  echo "Error: Release date is required!"
  echo
  usage
  exit 1
fi

# Validate device type
if [[ "$type" != "mini" && "$type" != "classic" && "$type" != "touch" ]]; then
  echo "Error: Invalid device type '$type'. Must be: mini, classic, or touch"
  exit 1
fi

echo
echo "Verifying OneKey $type firmware version $version"
echo "Git hash: $short_hash, Release date: $short_release_date"
echo

# Create the Dockerfile
create_dockerfile() {
  echo "Creating Dockerfile for OneKey firmware verification..."
  cat > onekey.dockerfile << 'EOF'
FROM ubuntu:20.04

# Set noninteractive mode to avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Update the package list and install dependencies
RUN apt update && apt -y upgrade && \
    apt install -y curl xz-utils sudo git wget g++ locales binutils file coreutils && \
    locale-gen en_US.UTF-8

# Create a non-root user 'nixuser' and group 'nixbld'
RUN groupadd -r nixbld && \
    useradd -m -s /bin/bash nixuser && \
    usermod -aG nixbld nixuser

# Create /nix directory and set permissions
RUN mkdir /nix && \
    chown nixuser:nixuser /nix

# Switch to 'nixuser'
USER nixuser
WORKDIR /home/nixuser

# Install Nix package manager
RUN curl -L https://nixos.org/nix/install | sh

# Source Nix profile (ensure Nix is in the PATH)
ENV USER nixuser
ENV PATH /home/nixuser/.nix-profile/bin:/home/nixuser/.nix-profile/sbin:$PATH
ENV NIX_PATH /home/nixuser/.nix-defexpr/channels

# Set the shell to bash
SHELL ["/bin/bash", "-c"]

# Create output directory with proper permissions
RUN mkdir -p /home/nixuser/output && chmod 755 /home/nixuser/output
EOF
}

prepare() {
  echo "Setting up verification environment..."
  
  # Setup working directory
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  create_dockerfile
}

build_and_verify() {
  echo "Building Docker image..."
  if ! $CONTAINER_CMD build -t $IMAGE_NAME -f onekey.dockerfile .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi

  echo "Running container to build and verify firmware..."
  
  # Run the Docker container and execute the build inside it
  verification_output=$($CONTAINER_CMD run --rm \
      -e TYPE="$type" \
      -e VERSION="$version" \
      -e SHORT_HASH="$short_hash" \
      -e SHORT_RELEASE_DATE="$short_release_date" \
      $IMAGE_NAME \
      bash -c '
      set -e
      source /home/nixuser/.nix-profile/etc/profile.d/nix.sh
      cd /home/nixuser

      # Clone the repository
      echo "Cloning OneKey firmware repository..."
      git clone https://github.com/OneKeyHQ/firmware.git
      cd firmware

      # Set environment variables for the build
      export FIRMWARE_VERSION="${VERSION}"
      export BUILD_DATE="${SHORT_RELEASE_DATE}"
      export SHORT_HASH="${SHORT_HASH}"
      export PRODUCTION=1

      # Check out the desired version
      echo "Checking out branch/tag: ${TYPE}/v${VERSION}"
      if ! git checkout "${TYPE}/v${VERSION}"; then
        echo "Failed to checkout ${TYPE}/v${VERSION}"
        echo "Available tags:"
        git tag | grep "${TYPE}" | head -10
        exit 1
      fi

      # Update submodules
      echo "Updating submodules..."
      git submodule update --init --recursive

      # Modify shell.nix if necessary
      if [[ -f shell.nix ]]; then
        sed -i "s|./pyright|./ci/pyright|" shell.nix
      fi

      # Enter Nix shell and install dependencies
      echo "Installing dependencies..."
      nix-shell --run "poetry install"

      # Build the firmware based on the device type
      echo "Building firmware for ${TYPE}..."
      if [[ "${TYPE}" == "mini" ]]; then
          nix-shell --run "export ONEKEY_MINI=1 && poetry run ./legacy/script/setup"
          nix-shell --run "export ONEKEY_MINI=1 && poetry run ./legacy/script/cibuild"
          built_firmware=$(find ./legacy/firmware -name "${TYPE}*Stable*.bin" -type f | head -1)
      elif [[ "${TYPE}" == "classic" ]]; then
          nix-shell --run "poetry run ./legacy/script/setup"
          nix-shell --run "poetry run ./legacy/script/cibuild"
          built_firmware=$(find ./legacy/firmware -name "${TYPE}*Stable*.bin" -type f | head -1)
      elif [[ "${TYPE}" == "touch" ]]; then
          nix-shell --run "poetry run make -C core build_boardloader"
          nix-shell --run "poetry run make -C core build_bootloader"
          nix-shell --run "poetry run make -C core build_firmware"
          nix-shell --run "poetry run core/tools/headertool.py -h core/build/firmware/touch*Stable*.bin"
          built_firmware=$(find ./core/build/firmware -name "${TYPE}*Stable*.bin" -type f | head -1)
      else
          echo "Invalid device type: ${TYPE}"
          exit 1
      fi

      if [[ -z "$built_firmware" || ! -f "$built_firmware" ]]; then
          echo "ERROR: Built firmware not found"
          exit 1
      fi

      echo "Built firmware: $built_firmware"
      built_hash=$(sha256sum "$built_firmware" | awk "{print \$1}")
      echo "Built firmware hash: $built_hash"

      # Download the official firmware for comparison
      echo "Downloading official firmware..."
      official_url="https://github.com/OneKeyHQ/firmware/releases/download/${TYPE}%2Fv${VERSION}/${TYPE}.${VERSION}-Stable-${SHORT_RELEASE_DATE}-${SHORT_HASH}.signed.bin"
      echo "Download URL: $official_url"
      
      if wget -O official-firmware.bin "$official_url"; then
          echo "Official firmware downloaded successfully"
          official_hash=$(sha256sum official-firmware.bin | awk "{print \$1}")
          echo "Official firmware hash: $official_hash"
          
          # Analyze differences if hashes don'\''t match
          if [[ "$built_hash" != "$official_hash" ]]; then
              echo "===== ANALYZING DIFFERENCES ====="
              
              # Get file sizes
              built_size=$(stat -c%s "$built_firmware")
              official_size=$(stat -c%s "official-firmware.bin")
              echo "Built firmware size:    $built_size bytes"
              echo "Official firmware size: $official_size bytes"
              
              # Enhanced binary diff analysis
              echo ""
              echo "=== DETAILED DIFFERENCE ANALYSIS ==="
              
              # Find all differing byte positions
              echo "Generating complete difference map..."
              diff_positions=$(cmp -l "$built_firmware" "official-firmware.bin" 2>/dev/null || true)
              total_diffs=$(echo "$diff_positions" | wc -l)
              echo "Total differing bytes: $total_diffs"
              
              if [[ "$total_diffs" -gt 0 ]]; then
                  # Analyze difference clustering
                  echo ""
                  echo "=== DIFFERENCE CLUSTERING ANALYSIS ==="
                  first_diff=$(echo "$diff_positions" | head -1 | awk '\''{print $1}'\'')
                  last_diff=$(echo "$diff_positions" | tail -1 | awk '\''{print $1}'\'')
                  echo "First difference at offset: $first_diff"
                  echo "Last difference at offset: $last_diff"
                  echo "Difference span: $((last_diff - first_diff)) bytes"
                  
                  # Check for contiguous regions
                  echo ""
                  echo "=== CONTIGUOUS DIFFERENCE REGIONS ==="
                  prev_offset=0
                  region_start=0
                  region_count=0
                  
                  echo "$diff_positions" | awk '\''{print $1}'\'' | while read offset; do
                      if [[ $((offset - prev_offset)) -gt 1 && $prev_offset -gt 0 ]]; then
                          if [[ $region_start -gt 0 ]]; then
                              echo "Region $((++region_count)): bytes $region_start to $prev_offset ($((prev_offset - region_start + 1)) bytes)"
                          fi
                          region_start=$offset
                      elif [[ $region_start -eq 0 ]]; then
                          region_start=$offset
                      fi
                      prev_offset=$offset
                  done
                  
                  # Show hex context around first few differences
                  echo ""
                  echo "=== HEX CONTEXT AROUND DIFFERENCES ==="
                  echo "$diff_positions" | head -5 | while read offset built_byte official_byte; do
                      start_offset=$((offset - 16))
                      if [[ $start_offset -lt 0 ]]; then
                          start_offset=0
                      fi
                      
                      echo ""
                      echo "--- Difference at offset $offset ---"
                      echo "Built firmware context (offset $start_offset):"
                      dd if="$built_firmware" bs=1 skip=$start_offset count=48 2>/dev/null | od -t x1 -A x | head -3
                      echo "Official firmware context (offset $start_offset):"
                      dd if="official-firmware.bin" bs=1 skip=$start_offset count=48 2>/dev/null | od -t x1 -A x | head -3
                      echo "Byte at $offset: built=0x$(printf %02x $built_byte) official=0x$(printf %02x $official_byte)"
                  done
                  
                  # Look for ASCII patterns in differences
                  echo ""
                  echo "=== SEARCHING FOR TEXT PATTERNS ==="
                  echo "Checking for timestamp-like patterns in differing regions..."
                  
                  # Extract differing regions as potential text
                  echo "$diff_positions" | head -20 | while read offset built_byte official_byte; do
                      # Check 32 bytes around difference for ASCII
                      start_check=$((offset - 16))
                      if [[ $start_check -lt 0 ]]; then
                          start_check=0
                      fi
                      
                      built_text=$(dd if="$built_firmware" bs=1 skip=$start_check count=32 2>/dev/null | strings -n 4 | head -1)
                      official_text=$(dd if="official-firmware.bin" bs=1 skip=$start_check count=32 2>/dev/null | strings -n 4 | head -1)
                      
                      if [[ -n "$built_text" || -n "$official_text" ]]; then
                          echo "Near offset $offset:"
                          echo "  Built:    '\''$built_text'\''"
                          echo "  Official: '\''$official_text'\''"
                      fi
                  done
                  
                  # Search for common timestamp patterns
                  echo ""
                  echo "=== TIMESTAMP PATTERN DETECTION ==="
                  
                  # Look for date patterns (YYYY-MM-DD, timestamps, etc.)
                  for pattern in "20[0-9][0-9]" "[0-9][0-9]:[0-9][0-9]" "T[0-9][0-9]:[0-9][0-9]"; do
                      built_matches=$(strings "$built_firmware" | grep -E "$pattern" | head -3)
                      official_matches=$(strings "official-firmware.bin" | grep -E "$pattern" | head -3)
                      
                      if [[ "$built_matches" != "$official_matches" ]]; then
                          echo "Pattern '\''$pattern'\'' differences:"
                          echo "  Built:    $built_matches"
                          echo "  Official: $official_matches"
                      fi
                  done
                  
                  # Look for build-related strings
                  echo ""
                  echo "=== BUILD METADATA DETECTION ==="
                  for keyword in "build" "compile" "version" "date" "time" "hash" "commit"; do
                      built_build=$(strings "$built_firmware" | grep -i "$keyword" | head -2)
                      official_build=$(strings "official-firmware.bin" | grep -i "$keyword" | head -2)
                      
                      if [[ "$built_build" != "$official_build" && (-n "$built_build" || -n "$official_build") ]]; then
                          echo "Keyword '\''$keyword'\'' differences:"
                          echo "  Built:    $built_build"
                          echo "  Official: $official_build"
                      fi
                  done
              fi
              
              echo "===== END DIFFERENCE ANALYSIS ====="
          fi
          
          echo "===== VERIFICATION SUMMARY ====="
          echo "Official firmware hash: $official_hash"
          echo "Built firmware hash:    $built_hash"
          echo "Hash comparison:        $(if [[ "$built_hash" == "$official_hash" ]]; then echo "IDENTICAL"; else echo "DIFFERENT"; fi)"
          echo "===== END SUMMARY ====="
      else
          echo "ERROR: Failed to download official firmware from $official_url"
          echo "This may indicate the version does not exist or network issues"
          verdict="download_failed"
          official_hash="unavailable"
      fi
      
      # Output results in a parseable format
      echo "RESULT_LINE:built_hash=$built_hash,official_hash=$official_hash"
      ' 2>&1)

  echo "$verification_output"
  
  # Parse results from output
  if echo "$verification_output" | grep -q "RESULT_LINE:"; then
    result_line=$(echo "$verification_output" | grep "RESULT_LINE:" | tail -1)
    built_hash=$(echo "$result_line" | sed 's/.*built_hash=\([^,]*\).*/\1/')
    official_hash=$(echo "$result_line" | sed 's/.*official_hash=\([^,]*\).*/\1/')
  else
    built_hash="unknown"
    official_hash="unknown"
  fi
}

result() {
  echo "===== Begin Results ====="
  echo "firmware:       OneKey $type"
  echo "version:        $version"
  echo "shortHash:      $short_hash"
  echo "releaseDate:    $short_release_date"
  echo "builtHash:      $built_hash"
  echo "officialHash:   $official_hash"
  echo "repository:     $repo"
  echo "tag:            $type/v$version"
  echo "===== End Results ====="
  
  if [ "$shouldCleanup" = false ]; then
    echo ""
    echo "Verification files available at: $workDir"
    echo "- Built firmware: Available in container"
    echo "- Official firmware: official-firmware.bin"
  fi
}

cleanup() {
  echo "Cleaning up temporary files..."
  $CONTAINER_CMD rmi $IMAGE_NAME -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
  if [ "$shouldCleanup" = true ]; then
    rm -rf "$workDir"
  fi
}

# Main execution
echo "Starting OneKey firmware verification with diff analysis..."
echo "This process may take 15-30 minutes depending on your system."
echo

prepare
echo "Environment prepared. Building and verifying firmware..."

build_and_verify
echo "Verification completed."

result
echo "Process completed."

cleanup
echo "OneKey firmware verification finished!"