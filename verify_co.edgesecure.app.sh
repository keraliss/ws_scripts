#!/bin/bash
# verify_co.edgesecure.app.sh v1.0.0 - Standalone verification script for Edge Wallet
# Usage: verify_co.edgesecure.app.sh -a path/to/edge.apk [-r revisionOverride] [-n] [-c]

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
wsContainer="docker.io/walletscrutiny/android:5"
takeUserActionCommand='echo "CTRL-D to continue";
  bash'
shouldCleanup=false

# Detect container runtime
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
else
    echo "Error: Neither Docker nor Podman found. Please install one of them."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Edge Wallet constants
repo="https://github.com/EdgeApp/edge-react-gui"

# Create Dockerfile content
create_dockerfile() {
  local build_tag="$1"
  local version_code="$2"
  local version_name="$3"
  
  cat > edge.dockerfile << EOF
FROM eclipse-temurin:17-jdk-jammy

ENV ANDROID_HOME="/opt/android-sdk" \\
    ANDROID_SDK_ROOT="/opt/android-sdk" \\
    PATH="\${PATH}:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools"

# Install Node.js 18.x and Yarn
RUN apt-get update && apt-get install -y \\
    git \\
    wget \\
    unzip \\
    curl \\
    && curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \\
    && apt-get install -y nodejs \\
    && npm install -g yarn \\
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p \${ANDROID_HOME}/cmdline-tools && \\
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip && \\
    unzip -q commandlinetools-linux-8512546_latest.zip -d \${ANDROID_HOME}/cmdline-tools && \\
    mv \${ANDROID_HOME}/cmdline-tools/cmdline-tools \${ANDROID_HOME}/cmdline-tools/latest && \\
    rm commandlinetools-linux-8512546_latest.zip

RUN yes | sdkmanager --licenses && \\
    sdkmanager "platform-tools" "platforms;android-33" "build-tools;33.0.0" "ndk;25.1.8937393"

RUN adduser --disabled-password --gecos '' appuser

# Give appuser write permissions to the Android SDK directory
RUN chown -R appuser:appuser \${ANDROID_HOME} && \\
    chmod -R 755 \${ANDROID_HOME}

USER appuser

WORKDIR /home/appuser

ENV NODE_ENV="development" \\
    AIRBITZ_API_KEY="74591cbad4a4938e0049c9d90d4e24091e0d4070" \\
    BUGSNAG_API_KEY="5aca2dbe708503471d8137625e092675"

RUN mkdir edge-react-gui && \\
    cd edge-react-gui && \\
    git clone --branch ${build_tag} --depth 1 --no-tags --single-branch https://github.com/EdgeApp/edge-react-gui/ .

WORKDIR /home/appuser/edge-react-gui

RUN sed -i "s/versionCode [0-9]*/versionCode ${version_code}/g" android/app/build.gradle && \\
    sed -i 's/versionName "[^"]*"/versionName "${version_name}"/g' android/app/build.gradle && \\
    sed -i "s/uploadReactNativeMappings = true/uploadReactNativeMappings = false/g" android/app/build.gradle && \\
    sed -i '/^\s*<\/application>\s*/i <meta-data android:name="com.bugsnag.android.BUILD_UUID" android:value="fd7bc623-0f99-40f8-b23d-527c1483d077"/>' android/app/src/main/AndroidManifest.xml && \\
    sed -i 's/BUGSNAG_API_KEY/5aca2dbe708503471d8137625e092675/g' android/app/src/main/AndroidManifest.xml

RUN yarn install && \\
    yarn prepare && \\
    sed -i 's/AIRBITZ_API_KEY": "/AIRBITZ_API_KEY": "74591cbad4a4938e0049c9d90d4e24091e0d4070/g' env.json && \\
    sed -i 's/BUGSNAG_API_KEY": "/BUGSNAG_API_KEY": "5aca2dbe708503471d8137625e092675/g' env.json

# Remove the package attribute only from the main app's AndroidManifest.xml
RUN sed -i 's/package="[^"]*"//g' android/app/src/main/AndroidManifest.xml

WORKDIR /home/appuser/edge-react-gui/android

RUN ./gradlew packageReleaseUniversalApk

# Find and copy the APK to a known location
RUN mkdir -p /home/appuser/output && \\
    find /home/appuser/edge-react-gui -name "*release*.apk" -exec cp {} /home/appuser/output/app-release-universal.apk \\;

WORKDIR /home/appuser/output

CMD ["tail", "-f", "/dev/null"]
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
  if ! $CONTAINER_CMD run \
    --rm \
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
    $CONTAINER_CMD run \
      --rm \
      --volume $DIR:/mnt:ro \
      --workdir /mnt \
      $wsContainer \
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256" | awk '{print $6}' )
  echo $s
}

usage() {
  echo 'NAME
       verify_co.edgesecure.app.sh - verify Edge Wallet build

SYNOPSIS
       verify_co.edgesecure.app.sh -a downloadedApk [-r revisionOverride] [-n] [-c]

DESCRIPTION
       This command tries to verify builds of Edge Wallet.

       -a|--apk The apk file we want to test.
       -r|--revision-override git revision id to use if tag is not found
       -n|--not-interactive The script will not ask for user actions
       -c|--cleanup Clean up temporary files after testing'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -a|--apk) downloadedApk="$2"; shift ;;
    -r|--revision-override) revisionOverride="$2"; shift ;;
    -n|--not-interactive) takeUserActionCommand='' ;;
    -c|--cleanup) shouldCleanup=true ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
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

appId=$(cat $fromPlayFolder/AndroidManifest.xml | head -n 1 | sed 's/.*package=\"//g' | sed 's/\".*//g')
versionName=$(cat $fromPlayFolder/apktool.yml | grep versionName | sed 's/.*\: //g' | sed "s/'//g")
versionCode=$(cat $fromPlayFolder/apktool.yml | grep versionCode | sed 's/.*\: //g' | sed "s/'//g")
workDir=/tmp/test_$appId

# Validate metadata
if [ -z "$appId" ]; then
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

# Verify this is Edge Wallet
if [ "$appId" != "co.edgesecure.app" ]; then
  echo "This script is only for Edge Wallet (co.edgesecure.app)"
  echo "Detected appId: $appId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Set up build variables
tag="v$versionName"
builtApk="$workDir/output/app-release-universal.apk"

prepare() {
  echo "Testing $appId from $repo revision $tag (revisionOverride: '$revisionOverride')..."
  # cleanup
  rm -rf "$workDir" || exit 1
  # create work directory
  mkdir -p $workDir/output
  cd $workDir
  
  commit=""  # Will be determined after build
}

test_edge() {
  echo "Starting Edge Wallet build process..."
  echo "This build uses Docker and may take 30-50 minutes..."
  
  # Determine tag to use
  local build_tag="$tag"
  if [ -n "$revisionOverride" ]; then
    build_tag="$revisionOverride"
  fi
  
  # Create Dockerfile
  echo "Creating Dockerfile..."
  create_dockerfile "$build_tag" "$versionCode" "$versionName"
  
  # Cleanup any existing containers/images
  echo "Cleaning up old Docker resources..."
  $CONTAINER_CMD rm -f edgeapp-container 2>/dev/null || true
  $CONTAINER_CMD rmi edgeapp-build -f 2>/dev/null || true
  
  echo "Building Docker image for Edge Wallet..."
  echo "Using tag: $build_tag"
  
  if ! $CONTAINER_CMD build \
    --tag edgeapp-build \
    --file edge.dockerfile .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  echo "Extracting built APK from container..."
  
  # Create container and copy APK
  if ! $CONTAINER_CMD create --name edgeapp-container edgeapp-build; then
    echo -e "${RED}Failed to create container!${NC}"
    exit 1
  fi
  
  if ! $CONTAINER_CMD cp edgeapp-container:/home/appuser/output/app-release-universal.apk "$builtApk"; then
    echo -e "${RED}Failed to copy APK from container!${NC}"
    $CONTAINER_CMD rm -f edgeapp-container
    exit 1
  fi
  
  # Get commit hash from the container
  commit=$($CONTAINER_CMD run --rm edgeapp-build bash -c "cd /home/appuser/edge-react-gui && git rev-parse HEAD" 2>/dev/null || echo "unknown")
  
  # Cleanup container
  $CONTAINER_CMD rm -f edgeapp-container
  
  # Cleanup Docker resources
  echo "Cleaning up Docker resources..."
  $CONTAINER_CMD rmi edgeapp-build -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
  
  echo "Edge Wallet build completed successfully!"
  
  # Verify the built APK exists
  if [ ! -f "$builtApk" ]; then
    echo -e "${RED}Error: Built APK not found at expected location: $builtApk${NC}"
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
  diffCount=$(echo "$diffResult" | grep -vcE "(META-INF|^$)" 2>/dev/null || echo "0")

  if [[ "$diffCount" =~ ^[0-9]+$ ]] && [ "$diffCount" -eq 0 ]; then
    verdict="reproducible"
  else
    verdict=""
  fi

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
  echo "verdict:        $verdict"
  echo "appHash:        $appHash"
  echo "commit:         $commit"
  echo ""
  echo "Diff:"
  echo "$diffResult"
  echo ""
  echo "Differences found (excluding META-INF): $diffCount"

  echo "===== End Results ====="
  echo "$diffGuide"
}

cleanup() {
  echo "Cleaning up..."
  rm -rf $fromPlayFolder $workDir $fromBuildUnzipped $fromPlayUnzipped
  # Cleanup Docker resources
  $CONTAINER_CMD rm -f edgeapp-container 2>/dev/null || true
  $CONTAINER_CMD rmi edgeapp-build -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
  # Remove temporary Dockerfile
  rm -f edge.dockerfile
}

# Main execution
echo "Starting Edge Wallet verification..."
echo "This process may take 40-60 minutes depending on your system."
echo

prepare
echo "Environment prepared. Starting build..."

test_edge
echo "Build completed. Running comparison..."

result
echo "Verification completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "Edge Wallet verification finished!"