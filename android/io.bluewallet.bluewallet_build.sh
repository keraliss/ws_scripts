#!/bin/bash
# io.bluewallet.bluewallet_build.sh v2.0.0 - Standardized verification script for BlueWallet
# Follows WalletScrutiny reproducible verification standards
# Usage: io.bluewallet.bluewallet_build.sh --apk APK_FILE

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
BUILD_TYPE="apk"
workDir="$(pwd)/bluewallet-work"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
wsContainer="docker.io/walletscrutiny/android:5"

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
else
    echo "Error: Neither podman nor docker found. Please install one of them."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# BlueWallet constants
repo="https://github.com/BlueWallet/BlueWallet"
appId="io.bluewallet.bluewallet"

# Create Dockerfile
create_dockerfile() {
  cat > "$workDir/Dockerfile" << EOF
FROM docker.io/node:18-bullseye-slim
ARG TAG
ARG VERSION
RUN set -ex; \\
    apt-get update; \\
    DEBIAN_FRONTEND=noninteractive apt-get install --yes \\
      -o APT::Install-Suggests=false --no-install-recommends \\
      patch git openjdk-17-jre-headless openjdk-17-jdk \\
      curl unzip zip; \\
    rm -rf /var/lib/apt/lists/*; \\
    deluser node; \\
    mkdir -p /Users/runner/work/1/;
ENV ANDROID_SDK_ROOT="/root/sdk" \\
    ANDROID_HOME="/root/sdk" \\
    NODE_ENV="production" \\
    JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
RUN set -ex; \\
    mkdir -p "\${ANDROID_HOME}/cmdline-tools"; \\
    cd "\${ANDROID_HOME}/cmdline-tools"; \\
    curl -O https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip; \\
    unzip commandlinetools-linux-9477386_latest.zip; \\
    mv cmdline-tools latest; \\
    rm commandlinetools-linux-9477386_latest.zip; \\
    echo "y" | "\${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" --install "platform-tools" "platforms;android-33" "build-tools;33.0.0"; \\
    mkdir -p "\${ANDROID_HOME}/licenses"; \\
    printf "\\n24333f8a63b6825ea9c5514f83c2829b004d1fee" > "\${ANDROID_HOME}/licenses/android-sdk-license"; \\
    printf "\\n84831b9409646a918e30573bab4c9c91346d8abd" > "\${ANDROID_HOME}/licenses/android-sdk-preview-license";
RUN set -ex; \\
    cd /Users/runner/work/1/; \\
    git clone --branch \$TAG https://github.com/BlueWallet/BlueWallet /Users/runner/work/1/s/; \\
    echo "sdk.dir=\${ANDROID_HOME}" > /Users/runner/work/1/s/android/local.properties;
WORKDIR /Users/runner/work/1/s/
RUN set -ex; \\
    npm config set fetch-retry-maxtimeout 600000; \\
    npm config set fetch-retry-mintimeout 100000; \\
    npm install --production --no-optional --omit=optional --no-audit --no-fund --ignore-scripts; \\
    npm run postinstall; \\
    rm -rf node_modules/realm; npm install realm; \\
    echo '"master"' > current-branch.json;
RUN set -ex; \\
    cd /Users/runner/work/1/s/android; \\
    chmod +x ./gradlew; \\
    ./gradlew assembleRelease \\
        -Dorg.gradle.internal.http.socketTimeout=600000 \\
        -Dorg.gradle.internal.http.connectionTimeout=600000
EOF
}

# Helper functions
containerApktool() {
  targetFolder=$1
  app=$2
  targetFolderParent=$(dirname "$targetFolder")
  targetFolderBase=$(basename "$targetFolder")
  appFolder=$(dirname "$app")
  appFile=$(basename "$app")

  if [ ! -f "$app" ]; then
    echo -e "${RED}Error: APK file not found: $app${NC}"
    return 1
  fi

  echo "Running apktool with $CONTAINER_CMD..."
  if ! $CONTAINER_CMD run --rm \
    --volume $targetFolderParent:/tfp \
    --volume $appFolder:/af:ro \
    $wsContainer \
    sh -c "apktool d -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""; then
    echo -e "${RED}Container apktool failed${NC}"
    return 1
  fi
  return 0
}

getSigner() {
  DIR=$(dirname "$1")
  BASE=$(basename "$1")
  s=$(
    $CONTAINER_CMD run --rm \
      --volume $DIR:/mnt:ro \
      --workdir /mnt \
      $wsContainer \
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256" | awk '{print $6}' )
  echo $s
}

usage() {
  echo 'NAME
       io.bluewallet.bluewallet_build.sh - verify BlueWallet build

SYNOPSIS
       io.bluewallet.bluewallet_build.sh --apk APK_FILE

DESCRIPTION
       This command verifies builds of BlueWallet.
       Version is automatically extracted from the APK.

       --apk       The apk file to test

EXAMPLES
       io.bluewallet.bluewallet_build.sh --apk bluewallet.apk
       io.bluewallet.bluewallet_build.sh --apk /path/to/bluewallet.apk'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --apk) downloadedApk="$2"; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Validate inputs
if [ ! -f "$downloadedApk" ]; then
  echo "APK file not found!"
  echo
  usage
  exit 1
fi

# Make path absolute
if ! [[ $downloadedApk =~ ^/.* ]]; then
  downloadedApk="$PWD/$downloadedApk"
fi

# Extract APK metadata
appHash=$(sha256sum "$downloadedApk" | awk '{print $1;}')
fromPlayFolder=/tmp/fromPlay$appHash
rm -rf $fromPlayFolder
signer=$(getSigner "$downloadedApk")
echo "Extracting APK content..."
containerApktool $fromPlayFolder "$downloadedApk" || exit 1

extractedAppId=$(cat $fromPlayFolder/AndroidManifest.xml | head -n 1 | sed 's/.*package=\"//g' | sed 's/\".*//g')
versionName=$(cat $fromPlayFolder/apktool.yml | grep versionName | sed 's/.*\: //g' | sed "s/'//g")
versionCode=$(cat $fromPlayFolder/apktool.yml | grep versionCode | sed 's/.*\: //g' | sed "s/'//g")

# Validate metadata
if [ -z "$extractedAppId" ]; then
  echo "appId could not be determined"
  exit 1
fi

if [ -z "$versionName" ]; then
  echo "versionName could not be determined"
  exit 1
fi

if [ -z "$versionCode" ]; then
  echo "versionCode could not be determined"
  exit 1
fi

# Verify this is BlueWallet
if [ "$extractedAppId" != "$appId" ]; then
  echo "This script is only for BlueWallet (io.bluewallet.bluewallet)"
  echo "Detected appId: $extractedAppId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Set up build variables
tag="v$versionName"
builtApk="$workDir/app-release-unsigned.apk"

prepare() {
  echo "Setting up workspace..."
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  echo -e "${GREEN}Environment prepared${NC}"
}

build_bluewallet() {
  echo "Starting BlueWallet build process..."
  
  cd "$workDir"
  
  echo "Creating Dockerfile..."
  create_dockerfile
  
  echo "Cleaning up any existing containers..."
  $CONTAINER_CMD rm -f bluewallet-container 2>/dev/null || true
  $CONTAINER_CMD rmi bluewallet-build -f 2>/dev/null || true
  
  echo "Building Docker image..."
  echo "This may take 20-40 minutes..."
  
  # Build with proper arguments
  build_args=""
  if [ "$CONTAINER_CMD" = "podman" ]; then
    build_args="--cgroup-manager cgroupfs --ulimit nofile=16384:16384"
  fi
  
  if ! $CONTAINER_CMD build \
    $build_args \
    --tag bluewallet-build \
    --build-arg TAG="$tag" \
    --build-arg VERSION="$versionCode" \
    --file Dockerfile \
    .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Docker image built successfully!${NC}"
  
  echo "Extracting APK from container..."
  if ! $CONTAINER_CMD run --rm \
    --volume "$workDir":/mnt \
    --user root \
    bluewallet-build \
    bash -c 'cp /Users/runner/work/1/s/android/app/build/outputs/apk/release/*.apk /mnt/'; then
    echo -e "${RED}APK extraction failed!${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}BlueWallet build completed successfully!${NC}"
  
  # Find the built APK
  builtApk=$(find "$workDir" -maxdepth 1 -name "*.apk" -type f | head -1)
  
  if [ -z "$builtApk" ] || [ ! -f "$builtApk" ]; then
    echo -e "${RED}Error: Built APK not found${NC}"
    echo "Checking workspace:"
    ls -la "$workDir"
    exit 1
  fi
  
  echo -e "${GREEN}Built APK found: $builtApk${NC}"
  echo "APK size: $(ls -lh "$builtApk" | awk '{print $5}')"
}

result() {
  echo "Setting up comparison..."
  fromPlayUnzipped=/tmp/fromPlay_${appId}_$versionCode
  fromBuildUnzipped=/tmp/fromBuild_${appId}_$versionCode
  rm -rf $fromBuildUnzipped $fromPlayUnzipped
  
  echo "Extracting APKs for comparison..."
  unzip -d $fromPlayUnzipped -qq "$downloadedApk" || exit 1
  unzip -d $fromBuildUnzipped -qq "$builtApk" || exit 1
  
  echo "Running diff comparison..."
  diffResult=$(diff --brief --recursive $fromPlayUnzipped $fromBuildUnzipped 2>/dev/null || true)
  
  # Count non-META-INF differences
  if [ -z "$diffResult" ]; then
    diffCount=0
  else
    diffCount=$(echo "$diffResult" | grep -vE "(META-INF|^$)" | wc -l || echo "0")
  fi
  
  verdict=""
  if [ "$diffCount" -eq 0 ]; then
    verdict="reproducible"
  else
    verdict="not_reproducible"
  fi

  builtHash=$(sha256sum "$builtApk" | awk '{print $1}')
  
  # Get commit from tag
  commit=$(git ls-remote --tags $repo | grep "refs/tags/$tag" | awk '{print $1}' | head -1)
  if [ -z "$commit" ]; then
    commit="unknown"
  fi

  echo "===== Begin Results ====="
  echo "appId:          $appId"
  echo "signer:         $signer"
  echo "apkVersionName: $versionName"
  echo "apkVersionCode: $versionCode"
  echo "verdict:        $verdict"
  echo "appHash:        $appHash"
  echo "builtHash:      $builtHash"
  echo "commit:         $commit"
  echo ""
  echo "Diff:"
  if [ -n "$diffResult" ]; then
    echo "$diffResult" | grep -vE "META-INF" || echo "(all differences were in META-INF)"
  else
    echo "(no differences)"
  fi
  echo ""
  echo "Differences found (excluding META-INF): $diffCount"
  echo "===== End Results ====="

  write_results "$verdict" "$appHash" "$([ "$verdict" = "reproducible" ] && echo 'true' || echo 'false')"
}

write_results() {
  local status=$1
  local hash=$2
  local match=$3
  
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+0000")
  
  cat > "$RESULTS_FILE" << EOF
date: ${timestamp}
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: android
    firmware_type: release
    files:
      - filename: app-release.apk
        hash: ${hash}
        match: ${match}
        expected_hash: ${hash}
        status: ${status}
        signer: ${signer}
        app_id: ${appId}
        version_name: ${versionName}
        version_code: ${versionCode}
EOF

  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

cleanup() {
  echo "Cleaning up Docker resources..."
  $CONTAINER_CMD rm -f bluewallet-container 2>/dev/null || true
  $CONTAINER_CMD rmi bluewallet-build -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting BlueWallet verification..."
echo "This process may take 30-50 minutes depending on your system."
echo

prepare
echo "Environment prepared. Starting build..."

build_bluewallet
echo "Build completed. Running comparison..."

result
echo "Verification completed."

cleanup

echo
echo "BlueWallet verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."