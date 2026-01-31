#!/bin/bash
# build_envoy.sh - Simple Android build script for Envoy (Passport hardware wallet companion app)
# Usage: build_envoy.sh [-d] [-c]

set -e

USE_DOCKER=false
CLEANUP=false

# Parse arguments
while getopts "dch" opt; do
    case $opt in
        d) USE_DOCKER=true ;;
        c) CLEANUP=true ;;
        h) echo "Usage: $0 [-d] [-c]"
           echo "  -d  Use Docker build (recommended)"
           echo "  -c  Cleanup after build"
           exit 0 ;;
        *) echo "Invalid option. Use -h for help." && exit 1 ;;
    esac
done

# Detect container runtime
if command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
fi

# Setup
mkdir -p envoy_build releases
cd envoy_build

# Clone/update Envoy
if [ ! -d "envoy" ]; then
    git clone https://github.com/Foundation-Devices/envoy.git
else
    cd envoy && git fetch origin && git reset --hard origin/main && cd ..
fi

if [ "$USE_DOCKER" = "true" ]; then
    # Docker build using simplified Dockerfile (without GitHub auth)
    if [ -z "$CONTAINER_CMD" ]; then
        echo "Error: Docker/Podman not found"
        exit 1
    fi
    
    # Create simplified Dockerfile
    cat > envoy/envoy-simple.dockerfile << 'EOF'
FROM ubuntu:24.04

ENV TZ=America/New_York
ARG DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    curl \
    build-essential \
    libssl-dev \
    pkg-config \
    git \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    openjdk-8-jdk \
    openjdk-21-jdk \
    wget \
    autoconf \
    clang \
    cmake \
    ninja-build \
    && apt clean && rm -rf /var/lib/apt/lists/*

# Install Android SDK
RUN update-java-alternatives --set /usr/lib/jvm/java-1.8.0-openjdk-amd64
RUN mkdir -p Android/sdk
ENV ANDROID_SDK_ROOT /root/Android/sdk
RUN mkdir -p .android && touch .android/repositories.cfg && \
    wget -O cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip && \
    unzip cmdline-tools.zip && rm cmdline-tools.zip && \
    mkdir -p Android/sdk/cmdline-tools && \
    mv cmdline-tools Android/sdk/cmdline-tools/latest
RUN export PATH="/root/Android/sdk/cmdline-tools/latest/bin:/root/Android/sdk/platform-tools:$PATH" && \
    cd /root && yes | sdkmanager --licenses && \
    sdkmanager "build-tools;30.0.2" "platform-tools" "platforms;android-30" && \
    sdkmanager "ndk;24.0.8215888"
ENV PATH="/root/Android/sdk/cmdline-tools/latest/bin:/root/Android/sdk/platform-tools:$PATH"

# Install Flutter
RUN update-java-alternatives --set /usr/lib/jvm/java-1.21.0-openjdk-amd64
RUN git clone https://github.com/flutter/flutter.git /root/flutter
ENV PATH="/root/flutter/bin:/root/Android/sdk/platform-tools:$PATH"

# Configure Flutter
RUN /root/flutter/bin/flutter channel stable
RUN cd /root/flutter && git checkout 3.35.1
RUN /root/flutter/bin/flutter config --enable-linux-desktop
RUN /root/flutter/bin/flutter precache

# Install Rust
RUN curl https://sh.rustup.rs -sSf | sh -s -- --default-toolchain stable -y
ENV PATH="/root/.cargo/bin:$PATH"

# Add Android targets for Rust
RUN /root/.cargo/bin/rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android

# Install bindgen-cli
RUN /root/.cargo/bin/cargo install --force --locked bindgen-cli

WORKDIR /workspace
EOF

    cd envoy
    $CONTAINER_CMD build -f envoy-simple.dockerfile -t envoy-android .
    $CONTAINER_CMD run --rm -v "$PWD:/workspace" -w /workspace envoy-android \
        bash -c "
            set -e
            echo '=== Checking Android SDK installation ==='
            ls -la /root/Android/sdk/
            
            echo '=== Checking available NDK versions ==='
            ls -la /root/Android/sdk/ndk/ 2>/dev/null || echo 'No NDK directory found'
            
            echo '=== Checking what packages are installed ==='
            sdkmanager --list_installed | grep -E '(ndk|build-tools|platform)'
            
            echo '=== Installing NDK if missing ==='
            sdkmanager 'ndk;24.0.8215888' || echo 'NDK installation failed, trying latest'
            sdkmanager --list | grep ndk | head -5
            
            echo '=== Checking NDK installation after retry ==='
            find /root/Android/sdk -name 'clang' -type f 2>/dev/null | head -10
            
            echo '=== Setting up environment ==='
            export ANDROID_SDK_ROOT=/root/Android/sdk
            export ANDROID_HOME=/root/Android/sdk
            
            # Find the actual clang location
            CLANG_PATH=\$(find /root/Android/sdk -name 'clang' -type f | head -1)
            if [ -n \"\$CLANG_PATH\" ]; then
                NDK_BIN_DIR=\$(dirname \"\$CLANG_PATH\")
                echo \"Found clang at: \$CLANG_PATH\"
                echo \"NDK bin directory: \$NDK_BIN_DIR\"
                
                export CC_aarch64_linux_android=\"\$CLANG_PATH\"
                export CXX_aarch64_linux_android=\"\$NDK_BIN_DIR/clang++\"
                export AR_aarch64_linux_android=\"\$NDK_BIN_DIR/llvm-ar\"
                export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=\"\$CLANG_PATH\"
                
                # Set target-specific flags
                export CFLAGS_aarch64_linux_android='-target aarch64-linux-android21'
                export CXXFLAGS_aarch64_linux_android='-target aarch64-linux-android21'
                
                export ANDROID_NDK_ROOT=\$(dirname \$(dirname \$(dirname \$(dirname \"\$NDK_BIN_DIR\"))))
                export NDK_HOME=\"\$ANDROID_NDK_ROOT\"
                
                echo \"Using NDK_HOME: \$NDK_HOME\"
                
                echo '=== Building FFI ==='
                chmod +x scripts/build_ffi_android.sh && ./scripts/build_ffi_android.sh
                
                echo '=== Building Flutter APK ==='
                flutter build apk --release
            else
                echo \"ERROR: Could not find clang even after NDK installation attempts\"
                echo \"Available files in Android SDK:\"
                find /root/Android/sdk -type f -name '*clang*' 2>/dev/null | head -10
                exit 1
            fi
        "
    
    mv build/app/outputs/flutter-apk/app-release.apk "../releases/envoy-$(date +%Y%m%d-%H%M%S).apk"
    cd ..
else
    # Local build
    cd envoy
    
    # Check dependencies
    if ! command -v flutter >/dev/null 2>&1; then
        echo "Error: Flutter not found"
        exit 1
    fi
    if ! command -v rustc >/dev/null 2>&1; then
        echo "Error: Rust not found"
        exit 1
    fi
    if [ -z "$ANDROID_SDK_ROOT" ]; then
        echo "Error: ANDROID_SDK_ROOT not set"
        exit 1
    fi
    
    # Build
    ./scripts/build_ffi_android.sh
    flutter build apk --release
    
    cp build/app/outputs/flutter-apk/app-release.apk "../releases/envoy-$(date +%Y%m%d-%H%M%S).apk"
    cd ..
fi

echo "✓ Android APK built successfully"
echo "Location: releases/envoy-*.apk"

# Cleanup
if [ "$CLEANUP" = "true" ]; then
    rm -rf envoy_build
    [ -n "$CONTAINER_CMD" ] && $CONTAINER_CMD image rm envoy-android 2>/dev/null || true
fi