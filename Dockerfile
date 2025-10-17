# OneKey Pro Firmware Build Environment
FROM ubuntu:24.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV NIX_VERSION=2.23.3
ENV FIRMWARE_VERSION=v4.14.0

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    pkg-config \
    libffi-dev \
    libssl-dev \
    libusb-1.0-0-dev \
    libudev-dev \
    python3-dev \
    python3-pip \
    python3-venv \
    curl \
    unzip \
    git \
    gcc \
    g++ \
    cpp \
    make \
    ca-certificates \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user for the build process
RUN useradd -m -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Switch to the builder user
USER builder
WORKDIR /home/builder

# Install Nix package manager
RUN curl -L https://releases.nixos.org/nix/nix-${NIX_VERSION}/install -o install-nix.sh && \
    chmod +x install-nix.sh && \
    ./install-nix.sh --no-daemon && \
    rm install-nix.sh

# Add Nix to PATH
ENV PATH="/home/builder/.nix-profile/bin:${PATH}"
ENV NIX_PATH="/home/builder/.nix-profile/bin"

# Clone the firmware-pro repository
RUN git clone https://github.com/OneKeyHQ/firmware-pro.git && \
    cd firmware-pro && \
    git checkout ${FIRMWARE_VERSION}

# Set working directory to firmware-pro
WORKDIR /home/builder/firmware-pro

# Initialize git submodules and install dependencies
RUN . /home/builder/.nix-profile/etc/profile.d/nix.sh && \
    nix-shell --run "poetry install" && \
    git submodule update --init --recursive

# Create the split firmware script
RUN cat > /home/builder/split_fw << 'EOF'
#!/bin/bash
if [ $# -ne 1 ]; then
  echo "Usage: $0 <binary_file>"
  exit 1
fi

INPUT_FILE="$1"
TOTAL_FILE_SIZE=$(stat -c %s "$INPUT_FILE")
MAGIC=$(dd if="$INPUT_FILE" bs=1 count=4 2>/dev/null)

calculate_total_size() {
  local offset=$1
  local size_bytes=$(dd if="$INPUT_FILE" bs=1 skip="$offset" count=4 2>/dev/null | od -An -tu4)
  echo $((size_bytes + 1024))
}

if [[ "$MAGIC" == "TRZF" ]]; then
  TOTAL_SIZE=$(calculate_total_size 12)
elif [[ "$MAGIC" == "OKTV" ]]; then
  HEAD1_SIZE=$(dd if="$INPUT_FILE" bs=1 skip=4 count=4 2>/dev/null | od -An -tu4)
  HEAD1_SIZE=$(echo $HEAD1_SIZE)
  FILE_SIZE_BYTES=$(dd if="$INPUT_FILE" bs=1 skip=$((HEAD1_SIZE + 12)) count=4 2>/dev/null | od -An -tu4)
  TOTAL_SIZE=$((HEAD1_SIZE + 1024 + FILE_SIZE_BYTES))
else
  echo "Unknown file format"
  exit 1
fi

dd if="$INPUT_FILE" bs=1 count="$TOTAL_SIZE" of=firmware.bin 2>/dev/null
echo "Extracted firmware saved as firmware.bin"
EOF

# Make the split script executable
RUN chmod +x /home/builder/split_fw

# Create a build script
RUN cat > /home/builder/build_firmware.sh << 'EOF'
#!/bin/bash
set -e

echo "Building OneKey Pro firmware..."
cd /home/builder/firmware-pro

# Source Nix environment
. /home/builder/.nix-profile/etc/profile.d/nix.sh

# Build the firmware
echo "Starting firmware compilation..."
PRODUCTION=1 nix-shell --run "poetry run make -C core build_firmware"

# Display build results
echo "Build completed successfully!"
echo "Firmware binary location: core/build/firmware/"
ls -la core/build/firmware/*.bin

# Calculate SHA256 of the built firmware (skip first 2560 bytes)
FIRMWARE_FILE=$(ls core/build/firmware/pro.*.bin | head -1)
if [ -f "$FIRMWARE_FILE" ]; then
    echo "Calculating SHA256 hash (skipping first 2560 bytes):"
    tail -c +2561 "$FIRMWARE_FILE" | shasum -a 256
fi
EOF

# Make the build script executable
RUN chmod +x /home/builder/build_firmware.sh

# Create a validation script
RUN cat > /home/builder/validate_firmware.sh << 'EOF'
#!/bin/bash
set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <signed_firmware_file>"
    echo "This script extracts MCU firmware from signed file and compares with local build"
    exit 1
fi

SIGNED_FILE="$1"

if [ ! -f "$SIGNED_FILE" ]; then
    echo "Error: File $SIGNED_FILE not found"
    exit 1
fi

echo "Extracting MCU firmware from signed file..."
/home/builder/split_fw "$SIGNED_FILE"

if [ ! -f "firmware.bin" ]; then
    echo "Error: Failed to extract firmware.bin"
    exit 1
fi

echo "Calculating SHA256 of extracted firmware (skipping first 2560 bytes):"
EXTRACTED_HASH=$(tail -c +2561 firmware.bin | shasum -a 256 | cut -d' ' -f1)
echo "Extracted firmware hash: $EXTRACTED_HASH"

# Find local build
LOCAL_FIRMWARE=$(ls /home/builder/firmware-pro/core/build/firmware/pro.*.bin 2>/dev/null | head -1)
if [ -f "$LOCAL_FIRMWARE" ]; then
    echo "Calculating SHA256 of local build (skipping first 2560 bytes):"
    LOCAL_HASH=$(tail -c +2561 "$LOCAL_FIRMWARE" | shasum -a 256 | cut -d' ' -f1)
    echo "Local build hash: $LOCAL_HASH"
    
    if [ "$EXTRACTED_HASH" = "$LOCAL_HASH" ]; then
        echo "✅ SUCCESS: Reproducible build verified! Hashes match."
    else
        echo "❌ FAIL: Hashes do not match. Build is not reproducible."
        exit 1
    fi
else
    echo "No local firmware build found. Run build_firmware.sh first."
    exit 1
fi
EOF

# Make the validation script executable
RUN chmod +x /home/builder/validate_firmware.sh

# Set the default command
CMD ["/bin/bash"]

# Add labels for documentation
LABEL maintainer="OneKey Build Environment"
LABEL description="Reproducible build environment for OneKey Pro firmware"
LABEL version="${FIRMWARE_VERSION}"