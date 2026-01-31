#!/bin/bash
# verify_ch.swissbitcoinpay.checkout.sh v1.0.0 - Standalone verification script for Swiss Bitcoin Pay
# Usage: verify_ch.swissbitcoinpay.checkout.sh -a path/to/swissbitcoinpay.apk [-r revisionOverride] [-n] [-c]

set -e

# Display disclaimer
echo -e "\033[1;33m"
echo "================================================================================================="
echo "This script downloads and builds Swiss Bitcoin Pay from source, then compares it with a"
echo "provided APK. It's for educational purposes to verify app reproducibility."
echo ""
echo "The script may take 15-45 minutes depending on your system and will use significant disk space."
echo "Requires Docker/Podman with internet access for downloading dependencies."
echo ""
echo "Only proceed if you understand the implications of running automated build scripts."
echo "================================================================================================="
echo -e "\033[0m"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
CONTAINER_CMD="docker"
workDir="/tmp/swissbitcoinpay_build_$$"
shouldCleanup=true

# App-specific variables
appId="ch.swissbitcoinpay.checkout"
repo="https://github.com/SwissBitcoinPay/app"
builtApk="$workDir/app/android/app/build/outputs/apk/release/app-release.apk"

# Default values
downloadedApk=""
revisionOverride=""
shouldCleanup=true

# Function to show usage
usage() {
    echo "Usage: $0 -a <apk_path> [-r <revision>] [-n] [-c]"
    echo "  -a: Path to the APK file to verify"
    echo "  -r: Git revision override (commit hash or tag)"
    echo "  -n: Don't cleanup temporary files (for debugging)"
    echo "  -c: Cleanup only - remove any existing temporary files and exit"
    exit 1
}

# Parse command line arguments
while getopts "a:r:nch" opt; do
    case $opt in
        a) downloadedApk="$OPTARG" ;;
        r) revisionOverride="$OPTARG" ;;
        n) shouldCleanup=false ;;
        c) 
            echo "Cleaning up any existing temporary files..."
            rm -rf /tmp/swissbitcoinpay_build_*
            $CONTAINER_CMD rmi swissbitcoinpay_builder -f 2>/dev/null || true
            $CONTAINER_CMD image prune -f 2>/dev/null || true
            echo "Cleanup completed."
            exit 0
            ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required arguments
if [ -z "$downloadedApk" ]; then
    echo -e "${RED}Error: APK path is required${NC}"
    usage
fi

if [ ! -f "$downloadedApk" ]; then
    echo -e "${RED}Error: APK file not found: $downloadedApk${NC}"
    exit 1
fi

# Check for container runtime
if ! command -v docker >/dev/null 2>&1; then
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
        echo "Using Podman as container runtime"
    else
        echo -e "${RED}Error: Neither Docker nor Podman found. Please install one of them.${NC}"
        exit 1
    fi
fi

prepare() {
    echo "Setting up build environment..."
    
    # Extract APK info
    echo "Analyzing provided APK..."
    if ! command -v aapt >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: aapt not found, trying alternative APK analysis...${NC}"
        # Try to extract basic info without aapt
        unzip -p "$downloadedApk" AndroidManifest.xml > /tmp/manifest_$$.xml 2>/dev/null || true
        versionName="unknown"
        versionCode="unknown"
    else
        versionName=$(aapt dump badging "$downloadedApk" | grep -oP "versionName='\K[^']+")
        versionCode=$(aapt dump badging "$downloadedApk" | grep -oP "versionCode='\K[^']+")
    fi
    
    echo "APK Version Name: $versionName"
    echo "APK Version Code: $versionCode"
    
    # Calculate APK hash
    appHash=$(sha256sum "$downloadedApk" | cut -d' ' -f1)
    signer=$(unzip -p "$downloadedApk" META-INF/*.RSA 2>/dev/null | openssl pkcs7 -inform DER -print_certs -noout 2>/dev/null | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | cut -d'=' -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]' || echo "unknown")
    
    # Create working directory
    rm -rf "$workDir"
    mkdir -p "$workDir"
    cd "$workDir"
    
    echo "Cloning Swiss Bitcoin Pay repository..."
    git clone "$repo" app
    cd app
    
    # Handle revision override
    if [ -n "$revisionOverride" ]; then
        echo "Using revision override: $revisionOverride"
        git checkout "$revisionOverride"
        commit=$(git rev-parse HEAD)
        tag="$revisionOverride"
    else
        # Try to find matching tag based on version
        if [ "$versionName" != "unknown" ]; then
            # Look for tags that might match the version
            possibleTags=$(git tag -l | grep -E "(v?$versionName|$versionName)" | head -1)
            if [ -n "$possibleTags" ]; then
                tag="$possibleTags"
                echo "Found matching tag: $tag"
                git checkout "$tag"
            else
                echo "No matching tag found for version $versionName, using latest commit"
                tag="main"
            fi
        else
            echo "Using latest commit from main branch"
            tag="main"
        fi
        commit=$(git rev-parse HEAD)
    fi
    
    echo "Building from commit: $commit"
    echo "Using tag/branch: $tag"
    
    # Create Dockerfile
    cat > Dockerfile << 'DOCKERFILE_END'
FROM node:18

# Install system dependencies
RUN apt-get update && apt-get install -y \
    openjdk-17-jdk \
    android-sdk \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install React Native CLI globally
RUN npm install -g @react-native-community/cli

# Set up Android SDK
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=$PATH:$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin

# Create Android SDK directory
RUN mkdir -p $ANDROID_HOME

# Download and install Android Command Line Tools
RUN cd $ANDROID_HOME && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip && \
    unzip commandlinetools-linux-9477386_latest.zip && \
    mkdir -p cmdline-tools/latest && \
    mv cmdline-tools/* cmdline-tools/latest/ && \
    rm commandlinetools-linux-9477386_latest.zip

# Accept licenses and install required packages
RUN yes | sdkmanager --licenses
RUN sdkmanager "platform-tools" "platforms;android-33" "build-tools;33.0.0"

# Set up React Native environment
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# Set working directory
WORKDIR /app

# Copy package files first for better caching
COPY package*.json ./

# Install dependencies
RUN npm ci

# Copy the rest of the source code
COPY . .

# Generate React Native bundle and build APK
RUN mkdir -p android/app/src/main/assets android/build/generated/autolinking && \
    echo '{}' > android/build/generated/autolinking/autolinking.json && \
    npx react-native bundle --platform android --dev false --entry-file index.js --bundle-output android/app/src/main/assets/index.android.bundle --assets-dest android/app/src/main/res/ && \
    cd android && \
    ./gradlew clean assembleRelease -x lint

DOCKERFILE_END
}

test_swissbitcoinpay() {
    echo "Starting Swiss Bitcoin Pay build process..."
    
    echo "Building Docker image for Swiss Bitcoin Pay..."
    echo "This may take several minutes to download and set up the build environment..."
    
    # Build the Docker image
    if ! $CONTAINER_CMD build --tag swissbitcoinpay_builder .; then
        echo -e "${RED}Docker build failed!${NC}"
        echo "Trying alternative build approach..."
        
        # Create a simpler Dockerfile for React Native
        cat > Dockerfile << 'DOCKERFILE_ALT_END'
FROM node:18

# Install system dependencies including Android build tools
RUN apt-get update && apt-get install -y \
    openjdk-17-jdk \
    wget \
    unzip \
    gradle \
    && rm -rf /var/lib/apt/lists/*

# Install React Native CLI globally
RUN npm install -g @react-native-community/cli

# Set up Android SDK
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=$PATH:$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# Create Android SDK directory and download tools
RUN mkdir -p $ANDROID_HOME && \
    cd $ANDROID_HOME && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip && \
    unzip commandlinetools-linux-9477386_latest.zip && \
    mkdir -p cmdline-tools/latest && \
    mv cmdline-tools/* cmdline-tools/latest/ 2>/dev/null || true && \
    rm -f commandlinetools-linux-9477386_latest.zip

# Accept licenses and install Android components
RUN yes | sdkmanager --licenses && \
    sdkmanager "platform-tools" "platforms;android-33" "build-tools;33.0.0" "ndk;25.1.8937393"

WORKDIR /app

CMD ["bash"]
DOCKERFILE_ALT_END

        if ! $CONTAINER_CMD build --tag swissbitcoinpay_builder .; then
            echo -e "${RED}Alternative Docker build also failed!${NC}"
            exit 1
        fi
    fi
    
    echo "Running container to build Swiss Bitcoin Pay..."
    echo "This build process may take 10-30 minutes..."
    
    # Run the container with the build commands
    if ! $CONTAINER_CMD run \
        --rm \
        --volume "$workDir/app:/app" \
        --workdir /app \
        swissbitcoinpay_builder \
        bash -c "
            set -e
            echo 'Installing Node.js dependencies...'
            npm ci
            
            echo 'Setting up React Native environment...'
            npx react-native info || true
            
            echo 'Creating autolinking configuration...'
            mkdir -p android/build/generated/autolinking
            echo '{}' > android/build/generated/autolinking/autolinking.json
            
            echo 'Running autolinking...'
            npx react-native config || true
            
            echo 'Building bundle for Metro...'
            npx react-native bundle --platform android --dev false --entry-file index.js --bundle-output android/app/src/main/assets/index.android.bundle --assets-dest android/app/src/main/res/ || true
            
            echo 'Building Android APK...'
            cd android
            echo 'Cleaning previous build...'
            ./gradlew clean
            echo 'Building release APK...'
            ./gradlew assembleRelease -x lint --stacktrace --info
        "; then
        echo -e "${RED}Container build failed!${NC}"
        echo "Trying alternative build approach without Metro bundling..."
        
        # Try simpler build without pre-bundling
        if ! $CONTAINER_CMD run \
            --rm \
            --volume "$workDir/app:/app" \
            --workdir /app \
            swissbitcoinpay_builder \
            bash -c "
                set -e
                echo 'Alternative build: skipping Metro bundle pre-generation...'
                cd android
                ./gradlew clean
                ./gradlew assembleRelease --no-daemon --stacktrace
            "; then
            echo -e "${RED}Alternative build also failed!${NC}"
            exit 1
        fi
    fi
    
    # Clean up Docker resources
    $CONTAINER_CMD rmi swissbitcoinpay_builder -f 2>/dev/null || true
    $CONTAINER_CMD image prune -f 2>/dev/null || true
    
    echo "Swiss Bitcoin Pay build completed successfully!"
    
    # Verify the built APK exists
    if [ ! -f "$builtApk" ]; then
        echo -e "${RED}Error: Built APK not found at expected location: $builtApk${NC}"
        echo "Checking build output directories:"
        find . -name "*.apk" -type f 2>/dev/null || echo "No APK files found"
        exit 1
    fi
    
    echo -e "${GREEN}Built APK found: $builtApk${NC}"
    echo "APK size: $(ls -lh "$builtApk" | awk '{print $5}')"
}

result() {
    echo "Setting up comparison..."
    fromPlayUnzipped="/tmp/fromPlay_${appId}_$versionCode"
    fromBuildUnzipped="/tmp/fromBuild_${appId}_$versionCode"
    rm -rf "$fromBuildUnzipped" "$fromPlayUnzipped"
    
    echo "Extracting APKs for comparison..."
    unzip -d "$fromPlayUnzipped" -qq "$downloadedApk" || exit 1
    unzip -d "$fromBuildUnzipped" -qq "$builtApk" || exit 1
    
    echo "Running diff comparison..."
    diffResult=$(diff --brief --recursive "$fromPlayUnzipped" "$fromBuildUnzipped" 2>/dev/null || true)
    diffCount=$(echo "$diffResult" | grep -vcE "(META-INF|^$)" || echo "0")

    diffGuide="
For detailed analysis, run:
diff --recursive $fromPlayUnzipped $fromBuildUnzipped
meld $fromPlayUnzipped $fromBuildUnzipped
diffoscope \"$downloadedApk\" \"$builtApk\""

    if [ "$shouldCleanup" = true ]; then
        diffGuide=''
    fi

    echo "===== Begin Results ====="
    echo "appId:          $appId"
    echo "signer:         $signer"
    echo "apkVersionName: $versionName"
    echo "apkVersionCode: $versionCode"
    echo "appHash:        $appHash"
    echo "commit:         $commit"
    echo ""
    echo "Diff:"
    echo "$diffResult"
    echo ""
    echo "Differences found (excluding META-INF): $diffCount"

    # Check git signatures
    echo ""
    echo "Checking git signatures..."
    tagInfo=$(git for-each-ref "refs/tags/$tag" 2>/dev/null || echo "")
    if [[ $tagInfo == *"tag"* ]]; then
        echo "Tag type: annotated"
        tagVerification=$(git tag -v "$tag" 2>&1) || true
        if [[ $tagVerification == *"Good signature"* ]]; then
            echo "✓ Good signature on annotated tag"
        else
            echo "⚠️ No valid signature found on annotated tag"
        fi
    else
        echo "Tag type: lightweight (cannot contain signature)"
    fi

    commitVerification=$(git verify-commit "$tag" 2>&1) || true
    if [[ $commitVerification == *"Good signature"* ]]; then
        echo "✓ Good signature on commit"
    else
        echo "⚠️ No valid signature found on commit"
    fi

    echo "===== End Results ====="
    echo "$diffGuide"
}

cleanup() {
    if [ "$shouldCleanup" = true ]; then
        echo "Cleaning up..."
        rm -rf "$workDir" "$fromBuildUnzipped" "$fromPlayUnzipped"
        $CONTAINER_CMD rmi swissbitcoinpay_builder -f 2>/dev/null || true
        $CONTAINER_CMD image prune -f 2>/dev/null || true
    else
        echo "Skipping cleanup (temporary files retained for debugging)"
        echo "Working directory: $workDir"
    fi
}

# Trap to ensure cleanup runs on script exit
trap cleanup EXIT

# Main execution
echo "Starting Swiss Bitcoin Pay verification..."
echo "This process may take 15-45 minutes depending on your system."
echo ""

prepare
echo "Repository prepared. Starting build..."

test_swissbitcoinpay
echo "Build completed. Running comparison..."

result
echo "Verification completed."