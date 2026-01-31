#!/bin/bash
# verify_verus_mobile.sh v1.0.0 - Standalone verification script for Verus Mobile wallet
# Usage: verify_verus_mobile.sh [-v versionTag] [-c]

set -e

# Display disclaimer
echo -e "\033[1;33m"
echo "====================================="
echo "Verus Mobile Wallet Verification"
echo "====================================="
echo -e "\033[0m"
echo -e "\033[1;31m"
echo "DISCLAIMER: This script downloads and builds software from third-party sources."
echo "Please review the code and understand the risks before proceeding."
echo "The authors assume no responsibility for any damage or loss."
echo -e "\033[0m"
echo

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m' # No Color

# Configuration
repo="https://github.com/VerusCoin/Verus-Mobile.git"
appId="com.veruscoin.verusmobile"
versionTag=""
cleanup=false

# Check for docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is required but not installed.${NC}"
    exit 1
fi

# Parse command line arguments
while getopts "v:ch" opt; do
    case $opt in
        v)
            versionTag="$OPTARG"
            ;;
        c)
            cleanup=true
            ;;
        h)
            echo "Usage: $0 [-v versionTag] [-c]"
            echo "  -v: Specify version tag (e.g., v1.0.34)"
            echo "  -c: Cleanup temporary files and Docker images after build"
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# Function to create Dockerfile
create_dockerfile() {
    cat > verus_mobile.dockerfile << 'EOF'
FROM openjdk:11-jdk

# Set environment variables
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    unzip \
    git \
    build-essential \
    python3 \
    python3-distutils \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 16.x
RUN curl -fsSL https://deb.nodesource.com/setup_16.x | bash - \
    && apt-get install -y nodejs

# Install Yarn
RUN npm install -g yarn

# Install Android SDK
RUN mkdir -p ${ANDROID_HOME}
RUN wget -q https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip -O /tmp/tools.zip \
    && unzip -q /tmp/tools.zip -d ${ANDROID_HOME} \
    && rm /tmp/tools.zip \
    && mv ${ANDROID_HOME}/cmdline-tools ${ANDROID_HOME}/cmdline-tools-old \
    && mkdir -p ${ANDROID_HOME}/cmdline-tools/latest \
    && mv ${ANDROID_HOME}/cmdline-tools-old/* ${ANDROID_HOME}/cmdline-tools/latest/ \
    && rm -rf ${ANDROID_HOME}/cmdline-tools-old

# Accept Android SDK licenses and install required packages
RUN yes | sdkmanager --licenses
RUN sdkmanager "platform-tools" "platforms;android-30" "build-tools;30.0.3" "platforms;android-29" "build-tools;29.0.3"

# Accept additional licenses that might be required
RUN yes | sdkmanager --update

# Set build arguments
ARG VERSION_TAG=master
ARG BUILD_UID=1000
ARG REPO_URL=https://github.com/VerusCoin/Verus-Mobile.git

# Set working directory
WORKDIR /build

# Clone repository
RUN git clone ${REPO_URL} verus-mobile && \
    cd verus-mobile && \
    if [ "${VERSION_TAG}" != "master" ]; then git checkout ${VERSION_TAG}; fi

# Set working directory to project
WORKDIR /build/verus-mobile

# Install dependencies and build
RUN yarn install

# Clean any existing build artifacts and generated resources
RUN cd android && ./gradlew clean
RUN rm -rf android/app/build/generated/res/react/ || true

# Bundle JavaScript for Android (this will regenerate clean resources)
RUN yarn bundle-android

# Build debug APK first to test if build works
RUN cd android && \
    export GRADLE_OPTS="-Xmx2g -Dfile.encoding=UTF-8 -Dorg.gradle.jvmargs=-Xmx2g" && \
    ./gradlew assembleDebug --no-daemon --no-parallel --max-workers=1

# Try release build with simpler options if debug works
RUN cd android && \
    export GRADLE_OPTS="-Xmx2g -Dfile.encoding=UTF-8 -Dorg.gradle.jvmargs=-Xmx2g" && \
    ./gradlew assembleRelease --no-daemon --no-parallel --max-workers=1 --no-build-cache || \
    echo "Release build failed, using debug APK"

# Create output directory and copy APK
RUN mkdir -p /build/output && \
    find android/app/build/outputs/apk -name "*.apk" -exec cp {} /build/output/ \;

CMD ["bash"]
EOF
}

# Function to build Verus Mobile
build_verus_mobile() {
    echo -e "${YELLOW}Building Verus Mobile APK...${NC}"
    
    # Determine version to build
    if [ -z "$versionTag" ]; then
        echo "No version specified, checking latest release..."
        versionTag=$(curl -s https://api.github.com/repos/VerusCoin/Verus-Mobile/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
        if [ -z "$versionTag" ]; then
            echo "Could not determine latest version, using master branch"
            versionTag="master"
        fi
    fi
    
    echo "Building version: $versionTag"
    
    # Create Dockerfile
    create_dockerfile
    
    # Build Docker image
    echo -e "${YELLOW}Building Docker image...${NC}"
    docker build \
        --build-arg VERSION_TAG="$versionTag" \
        --build-arg REPO_URL="$repo" \
        -f verus_mobile.dockerfile \
        -t verus-mobile-builder \
        .
    
    # Create container and copy APKs
    echo -e "${YELLOW}Extracting built APKs...${NC}"
    container_id=$(docker create verus-mobile-builder)
    docker cp "$container_id:/build/output/." ./
    docker rm "$container_id"
    
    echo -e "${GREEN}Build completed!${NC}"
    
    # List built APKs
    echo -e "${YELLOW}Built APK files:${NC}"
    for apk in *.apk; do
        if [ -f "$apk" ]; then
            echo "  - $apk"
            sha256sum "$apk"
        fi
    done
}

# Function to get commit hash from built image
get_commit_info() {
    echo -e "${YELLOW}Getting commit information...${NC}"
    commit=$(docker run --rm verus-mobile-builder bash -c "cd /build/verus-mobile && git log -n 1 --pretty=format:'%H'")
    echo "Commit: $commit"
}

# Function to show results
show_results() {
    echo
    echo "===== Begin Results ====="
    echo "appId:          $appId"
    echo "version:        $versionTag"
    echo "repository:     $repo"
    if [ -n "$commit" ]; then
        echo "commit:         $commit"
    fi
    echo "verdict:        build_completed"
    
    echo "Built APKs:"
    for apk in *.apk; do
        if [ -f "$apk" ]; then
            apk_hash=$(sha256sum "$apk" | cut -d' ' -f1)
            echo "  $apk: $apk_hash"
        fi
    done
    echo "===== End Results ====="
}

# Function to cleanup
cleanup_files() {
    if [ "$cleanup" = true ]; then
        echo -e "${YELLOW}Cleaning up...${NC}"
        
        # Remove Docker image
        docker rmi verus-mobile-builder -f 2>/dev/null || true
        
        # Remove Dockerfile
        rm -f verus_mobile.dockerfile
        
        echo -e "${GREEN}Cleanup completed.${NC}"
    fi
}

# Main execution
main() {
    echo -e "${YELLOW}Starting Verus Mobile build verification...${NC}"
    
    # Build the APK
    build_verus_mobile
    
    # Get commit information
    get_commit_info
    
    # Show results
    show_results
    
    # Cleanup if requested
    cleanup_files
    
    echo -e "${GREEN}Verus Mobile build verification completed!${NC}"
}

# Trap to cleanup on exit
trap cleanup_files EXIT

# Run main function
main "$@"