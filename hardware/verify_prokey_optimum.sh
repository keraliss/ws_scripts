#!/bin/bash
# verify_prokey_optimum.sh v1.0.0 - Standalone verification script for Prokey Optimum Hardware Wallet
# Usage: verify_prokey_optimum.sh -v version [-c]

set -e

# Display disclaimer
echo -e "\033[1;33m"
echo "=============================================================================="
echo " PROKEY OPTIMUM FIRMWARE VERIFICATION SCRIPT"
echo "=============================================================================="
echo " This script downloads and builds Prokey Optimum firmware from source,"
echo " then compares it with the official firmware to verify reproducibility."
echo ""
echo " WARNING: This script downloads and executes code. Please review the source"
echo " code before running. Use at your own risk."
echo "=============================================================================="
echo -e "\033[0m"

# Script variables
SCRIPT_VERSION="1.0.0"
REPO_URL="https://github.com/prokey-io/prokey-optimum-firmware.git"
DOCKER_IMAGE="prokey-optimum-verification"
VERIFICATION_DIR="/tmp/prokey-optimum-verification"
FIRMWARE_DIR="$VERIFICATION_DIR/prokey-optimum-firmware"
BUILD_DIR="$FIRMWARE_DIR/firmware"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
VERSION=""
CLEAN_AFTER=false

# Function to display usage
usage() {
    echo "Usage: $0 -v VERSION [-c]"
    echo ""
    echo "Arguments:"
    echo "  -v VERSION    Firmware version to verify (e.g., '1.0.0')"
    echo "  -c           Clean up after verification"
    echo "  -h           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -v 1.0.0"
    echo "  $0 -v 1.0.0 -c"
    echo ""
}

# Function to log messages
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Function to log errors
error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to log success
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to log warnings
warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if Docker is available
check_docker() {
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed or not in PATH"
        echo "Please install Docker first: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running"
        echo "Please start Docker daemon first"
        exit 1
    fi
}

# Function to create Dockerfile
create_dockerfile() {
    log "Creating Dockerfile for Prokey Optimum build environment..."
    
    cat > "$VERIFICATION_DIR/Dockerfile" << 'EOF'
FROM ubuntu:18.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Set working directory
WORKDIR /workspace

# Install system dependencies
RUN apt-get update && apt-get install -y \
    wget \
    curl \
    git \
    python3.6 \
    python3-pip \
    python3.6-dev \
    python3.6-venv \
    build-essential \
    unzip \
    nano \
    && rm -rf /var/lib/apt/lists/*

# Make python3.6 the default python
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.6 10
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.6 10

# Install pip for Python 3.6
RUN curl https://bootstrap.pypa.io/pip/3.6/get-pip.py | python3.6

# Install pipenv
RUN pip3 install pipenv protobuf==3.19.4
ENV PATH="/root/.local/bin:${PATH}"

# Set Python environment variables for pipenv
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PIPENV_PYTHON=python3.6
ENV PIPENV_VENV_IN_PROJECT=1

# Download and install GNU ARM Embedded Toolchain
RUN wget -q https://developer.arm.com/-/media/Files/downloads/gnu/11.2-2022.02/binrel/gcc-arm-11.2-2022.02-x86_64-arm-none-eabi.tar.xz \
    && mkdir -p /opt/gcc-arm \
    && tar -xf gcc-arm-11.2-2022.02-x86_64-arm-none-eabi.tar.xz -C /opt/gcc-arm/ \
    && mv /opt/gcc-arm/gcc-arm-11.2-2022.02-x86_64-arm-none-eabi /opt/gcc-arm/gcc-arm \
    && rm gcc-arm-11.2-2022.02-x86_64-arm-none-eabi.tar.xz

# Add ARM toolchain to PATH
ENV PATH="/opt/gcc-arm/gcc-arm/bin:${PATH}"

# Download and install Protobuf compiler
RUN wget -q https://github.com/protocolbuffers/protobuf/releases/download/v3.19.4/protoc-3.19.4-linux-x86_64.zip \
    && mkdir -p /opt/protoc \
    && unzip protoc-3.19.4-linux-x86_64.zip -d /opt/protoc \
    && rm protoc-3.19.4-linux-x86_64.zip

# Add protoc to PATH
ENV PATH="/opt/protoc/bin:${PATH}"

# Verify installations
RUN arm-none-eabi-gcc --version \
    && protoc --version \
    && python --version \
    && pipenv --version

# Set entrypoint
COPY build-firmware.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/build-firmware.sh

ENTRYPOINT ["build-firmware.sh"]
EOF
    
    success "Dockerfile created"
}

# Function to create build script
create_build_script() {
    log "Creating build script..."
    
    cat > "$VERIFICATION_DIR/build-firmware.sh" << 'EOF'
#!/bin/bash
set -e

echo "=== Starting Prokey Optimum firmware build ==="

# Check if we're in the firmware directory
if [ ! -f "Pipfile" ] || [ ! -d "script" ]; then
    echo "Error: Not in prokey-optimum-firmware directory"
    exit 1
fi

echo "Checking Pipfile contents:"
cat Pipfile

echo ""
echo "Checking if Pipfile.lock exists:"
ls -la Pipfile*

# Set Python environment variables
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PIPENV_PYTHON=python3.6

echo "Python version: $(python3.6 --version)"
echo "Pipenv version: $(pipenv --version)"

echo "Installing Python dependencies..."
pipenv install --python python3.6

echo "Installing additional required packages in pipenv..."
pipenv install protobuf

echo "Verifying protobuf installation..."
pipenv run python -c "import google.protobuf; print('Protobuf version:', google.protobuf.__version__)"

echo "Setting up repository..."
pipenv run script/setup

echo "Building firmware..."
pipenv run script/cibuild

echo "Build completed successfully!"

# Show build artifacts
if [ -f "firmware/prokey.elf" ]; then
    echo "Build artifacts found:"
    ls -la firmware/
    echo ""
    echo "Firmware hash:"
    sha256sum firmware/prokey.elf
else
    echo "Warning: Expected firmware binary not found"
    echo "Available files:"
    find . -name "*.bin" -o -name "*.elf" -o -name "*.hex" | head -10
    echo ""
    echo "Searching for any potential firmware files:"
    find . -type f -size +1k \( -name "*firmware*" -o -name "*prokey*" \) | head -5
fi
EOF
    
    success "Build script created"
}

# Function to get official firmware download URL
get_official_firmware_url() {
    local version="$1"
    
    # TODO: Need to determine the actual download URL pattern for Prokey Optimum
    # This is a placeholder - need to check Prokey's actual release structure
    warn "Official firmware download URL needs to be determined"
    warn "Prokey may not provide direct binary downloads"
    
    # Possible locations to check:
    # - GitHub releases: https://github.com/prokey-io/prokey-optimum-firmware/releases
    # - Official website: https://prokey.io
    # - Support documentation
    
    echo ""
    error "Cannot determine official firmware download URL for version $version"
    error "This script needs to be updated with the correct download pattern"
    exit 1
}

# Function to download official firmware
download_official_firmware() {
    local version="$1"
    
    log "Attempting to download official firmware for version $version..."
    
    # Try different possible download locations
    local base_urls=(
        "https://github.com/prokey-io/prokey-optimum-firmware/releases/download/v${version}"
        "https://prokey.io/downloads/firmware"
        "https://support.prokey.io/firmware"
    )
    
    local firmware_files=(
        "prokey-optimum-v${version}.bin"
        "prokey-optimum-${version}.bin"
        "firmware-v${version}.bin"
        "firmware.bin"
    )
    
    local downloaded=false
    
    for base_url in "${base_urls[@]}"; do
        for firmware_file in "${firmware_files[@]}"; do
            local full_url="${base_url}/${firmware_file}"
            log "Trying: $full_url"
            
            if curl -L --fail --connect-timeout 10 --max-time 30 \
                -o "$VERIFICATION_DIR/official-firmware.bin" \
                "$full_url" 2>/dev/null; then
                success "Downloaded official firmware from: $full_url"
                downloaded=true
                break 2
            fi
        done
    done
    
    if [ "$downloaded" = false ]; then
        error "Could not download official firmware"
        error "Please check if version $version exists and download manually"
        error "Place the official firmware as: $VERIFICATION_DIR/official-firmware.bin"
        exit 1
    fi
}

# Function to build Docker image
build_docker_image() {
    log "Building Docker image: $DOCKER_IMAGE"
    
    cd "$VERIFICATION_DIR"
    docker build -t "$DOCKER_IMAGE" .
    
    success "Docker image built successfully"
}

# Function to clone and build firmware
build_firmware() {
    local version="$1"
    
    log "Cloning Prokey Optimum firmware repository..."
    
    if [ -d "$FIRMWARE_DIR" ]; then
        log "Removing existing firmware directory..."
        rm -rf "$FIRMWARE_DIR"
    fi
    
    git clone "$REPO_URL" "$FIRMWARE_DIR"
    cd "$FIRMWARE_DIR"
    
    # Checkout specific version if provided
    if [ -n "$version" ]; then
        log "Checking out version: $version"
        if git tag -l | grep -q "^v${version}$"; then
            git checkout "v${version}"
        elif git tag -l | grep -q "^${version}$"; then
            git checkout "${version}"
        else
            warn "Version tag $version not found, using latest master"
        fi
    fi
    
    log "Building firmware in Docker container..."
    
    docker run --rm \
        -v "$FIRMWARE_DIR":/workspace \
        "$DOCKER_IMAGE"
    
    success "Firmware build completed"
}

# Function to find built firmware binary
find_built_firmware() {
    log "Searching for built firmware binary..."
    
    # Common locations for built firmware
    local search_paths=(
        "$BUILD_DIR/prokey.elf"
        "$BUILD_DIR/prokey.bin"
        "$FIRMWARE_DIR/build/prokey.bin"
        "$FIRMWARE_DIR/build/firmware.bin"
        "$FIRMWARE_DIR/output/prokey.bin"
    )
    
    for path in "${search_paths[@]}"; do
        if [ -f "$path" ]; then
            success "Found built firmware: $path"
            echo "$path"
            return 0
        fi
    done
    
    # Search more broadly
    log "Searching for any binary files..."
    local found_binaries=$(find "$FIRMWARE_DIR" -name "*.bin" -o -name "*.elf" -o -name "*.hex" 2>/dev/null | head -5)
    
    if [ -n "$found_binaries" ]; then
        warn "Could not find firmware in expected location"
        warn "Found these binary files:"
        echo "$found_binaries"
        
        # Use the first found binary
        local first_binary=$(echo "$found_binaries" | head -1)
        warn "Using: $first_binary"
        echo "$first_binary"
        return 0
    fi
    
    error "No built firmware binary found"
    return 1
}

# Function to compare firmware binaries
compare_firmware() {
    local built_firmware="$1"
    
    if [ ! -f "$VERIFICATION_DIR/official-firmware.bin" ]; then
        error "Official firmware not found"
        return 1
    fi
    
    if [ ! -f "$built_firmware" ]; then
        error "Built firmware not found: $built_firmware"
        return 1
    fi
    
    log "Comparing firmware binaries..."
    
    # Calculate hashes
    local official_hash=$(sha256sum "$VERIFICATION_DIR/official-firmware.bin" | cut -d' ' -f1)
    local built_hash=$(sha256sum "$built_firmware" | cut -d' ' -f1)
    
    echo ""
    echo "=========================="
    echo "VERIFICATION RESULTS:"
    echo "Official firmware: $official_hash"
    echo "Built firmware:    $built_hash"
    
    if [ "$official_hash" = "$built_hash" ]; then
        echo "✓ REPRODUCIBLE: Firmware hashes match"
        echo "=========================="
        return 0
    else
        echo "✗ NOT REPRODUCIBLE: Firmware hashes differ"
        echo "=========================="
        return 1
    fi
}

# Function to output results in standard format
output_results() {
    local version="$1"
    local verdict="$2"
    local official_hash="$3"
    local built_hash="$4"
    local built_firmware="$5"
    
    echo ""
    echo "===== Begin Results ====="
    echo "firmware:       Prokey Optimum"
    echo "version:        $version"
    echo "verdict:        $verdict"
    echo "officialHash:   $official_hash"
    echo "builtHash:      $built_hash"
    echo "repository:     $REPO_URL"
    if [ -n "$version" ]; then
        echo "tag:            v$version"
    fi
    if [ "$verdict" = "reproducible" ]; then
        echo "✓ The firmware builds reproducibly from source code."
    else
        echo "✗ The firmware does not build reproducibly."
    fi
    echo "===== End Results ====="
    
    echo ""
    echo "Verification files available at: $VERIFICATION_DIR"
    echo "- Official firmware: official-firmware.bin"
    echo "- Built firmware: $(basename "$built_firmware")"
    echo "Verification completed."
    echo "Prokey Optimum firmware verification finished!"
}

# Function to cleanup
cleanup() {
    if [ "$CLEAN_AFTER" = true ]; then
        log "Cleaning up verification files..."
        rm -rf "$VERIFICATION_DIR"
        docker rmi "$DOCKER_IMAGE" 2>/dev/null || true
        success "Cleanup completed"
    fi
}

# Parse command line arguments
while getopts "v:ch" opt; do
    case $opt in
        v)
            VERSION="$OPTARG"
            ;;
        c)
            CLEAN_AFTER=true
            ;;
        h)
            usage
            exit 0
            ;;
        \?)
            error "Invalid option: -$OPTARG"
            usage
            exit 1
            ;;
    esac
done

# Validate arguments
if [ -z "$VERSION" ]; then
    error "Version is required"
    usage
    exit 1
fi

# Main execution
main() {
    log "Starting Prokey Optimum firmware verification for version $VERSION"
    
    # Setup
    check_docker
    mkdir -p "$VERIFICATION_DIR"
    
    # Create build environment
    create_dockerfile
    create_build_script
    build_docker_image
    
    # Download official firmware (may fail if not available)
    # download_official_firmware "$VERSION"
    
    # Build firmware from source
    build_firmware "$VERSION"
    
    # Find built firmware
    built_firmware=$(find_built_firmware)
    if [ $? -ne 0 ]; then
        cleanup
        exit 1
    fi
    
    # Compare if official firmware is available
    if [ -f "$VERIFICATION_DIR/official-firmware.bin" ]; then
        if compare_firmware "$built_firmware"; then
            verdict="reproducible"
        else
            verdict="not reproducible"
        fi
        
        official_hash=$(sha256sum "$VERIFICATION_DIR/official-firmware.bin" | cut -d' ' -f1)
        built_hash=$(sha256sum "$built_firmware" | cut -d' ' -f1)
        
        output_results "$VERSION" "$verdict" "$official_hash" "$built_hash" "$built_firmware"
    else
        warn "Official firmware not available for comparison"
        warn "Only verifying that firmware builds successfully from source"
        
        built_hash=$(sha256sum "$built_firmware" | cut -d' ' -f1)
        
        echo ""
        echo "===== Begin Results ====="
        echo "firmware:       Prokey Optimum"
        echo "version:        $VERSION"
        echo "verdict:        build-only"
        echo "builtHash:      $built_hash"
        echo "repository:     $REPO_URL"
        echo "tag:            v$VERSION"
        echo "✓ The firmware builds successfully from source code."
        echo "Note: Official firmware not available for comparison."
        echo "===== End Results ====="
    fi
    
    # Cleanup
    cleanup
}

# Run main function
main

success "Prokey Optimum verification script completed"