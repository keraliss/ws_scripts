#!/bin/bash
# verify_io.horizontalsystems.bankwallet.sh v1.0.0 - Standalone verification script for Unstoppable Wallet
# Usage: verify_io.horizontalsystems.bankwallet.sh -a path/to/unstoppable.apk [-r revisionOverride] [-n] [-c]

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
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
else
    echo "Error: Neither Podman nor Docker found. Please install one of them."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Unstoppable Wallet constants
repo="https://github.com/horizontalsystems/unstoppable-wallet-android.git"

# Create Dockerfile content
create_dockerfile() {
  cat > unstoppable.dockerfile << 'EOF'
FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
  apt-get install -y wget \
    openjdk-17-jre-headless \
    openjdk-17-jdk-headless \
    git unzip && \
  rm -rf /var/lib/apt/lists/* && \
  apt-get autoremove -y && \
  apt-get clean

# download and install Android SDK
ENV ANDROID_HOME /opt/android-sdk
RUN mkdir -p /opt/android-sdk/cmdline-tools && \
  cd /opt/android-sdk/cmdline-tools && \
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-7583922_latest.zip && \
  unzip *.zip && \
  rm -f *.zip && \
  ln -s /opt/android-sdk/cmdline-tools/cmdline-tools/bin/sdkmanager /usr/bin/sdkmanager && \
  yes | sdkmanager --licenses && \
  sdkmanager "build-tools;33.0.1" && \
  ln -s /opt/android-sdk/build-tools/33.0.1/apksigner /usr/bin/apksigner && \
  wget https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool && \
  wget https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.4.1.jar && \
  mv *.jar apktool.jar && \
  mv apktool apktool.jar /usr/local/bin/ && \
  chmod +x /usr/local/bin/apktool /usr/local/bin/apktool.jar

# following https://github.com/Microsoft/vscode-arduino/issues/644#issuecomment-415329398
RUN rm /etc/java-17-openjdk/accessibility.properties
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
       verify_io.horizontalsystems.bankwallet.sh - verify Unstoppable Wallet build

SYNOPSIS
       verify_io.horizontalsystems.bankwallet.sh -a downloadedApk [-r revisionOverride] [-n] [-c]

DESCRIPTION
       This command tries to verify builds of Unstoppable Wallet.

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

# Verify this is Unstoppable Wallet
if [ "$appId" != "io.horizontalsystems.bankwallet" ]; then
  echo "This script is only for Unstoppable Wallet (io.horizontalsystems.bankwallet)"
  echo "Detected appId: $appId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Set up build variables
tag="$versionName"
builtApk="$workDir/app/app/build/outputs/apk/base/release/app-base-release.apk"

prepare() {
  echo "Testing $appId from $repo revision $tag (revisionOverride: '$revisionOverride')..."
  # cleanup
  rm -rf "$workDir" || exit 1
  # create work directory
  mkdir -p $workDir
  cd $workDir
  # clone
  echo "Cloning repository..."
  if [ -n "$revisionOverride" ]; then
    git clone --quiet $repo app && cd app && git checkout "$revisionOverride" || exit 1
  else
    git clone --quiet --branch "$tag" --depth 1 $repo app && cd app || exit 1
  fi
  commit=$(git log -n 1 --pretty=oneline | sed 's/ .*//g')
}

test_unstoppable() {
  echo "Starting Unstoppable Wallet build process..."
  echo "This build process may take 30-60 minutes and requires 12GB memory..."
  
  # Create Dockerfile
  echo "Creating Dockerfile..."
  create_dockerfile
  
  # Cleanup any existing container
  echo "Cleaning up any existing containers..."
  $CONTAINER_CMD rm -f unstoppable-container 2>/dev/null || true
  
  # Build Docker image
  echo "Building Docker image for Unstoppable Wallet..."
  if ! $CONTAINER_CMD build -t unstoppable-build -f unstoppable.dockerfile .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  echo "Running Gradle build in container..."
  echo "Note: This may take a long time and requires significant memory..."
  
  # Run the build
  if ! $CONTAINER_CMD run -it \
    --volume $PWD:/mnt \
    --workdir /mnt \
    --memory=12g \
    --name unstoppable-container \
    unstoppable-build \
    bash -x -c './gradlew clean && ./gradlew :app:assembleBaseRelease --no-daemon --max-workers=2 --info'; then
    echo -e "${RED}Gradle build failed!${NC}"
    # Cleanup container even on failure
    $CONTAINER_CMD rm -f unstoppable-container 2>/dev/null || true
    exit 1
  fi
  
  # Cleanup container
  echo "Cleaning up build container..."
  $CONTAINER_CMD rm -f unstoppable-container 2>/dev/null || true
  
  echo "Unstoppable Wallet build completed successfully!"
  
  # Verify the built APK exists
  if [ ! -f "$builtApk" ]; then
    echo -e "${RED}Error: Built APK not found at expected location: $builtApk${NC}"
    echo "Checking build output directories:"
    find app/build/outputs/apk/ -name "*.apk" 2>/dev/null || echo "No APK files found"
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
  diffCount=$(echo "$diffResult" | grep -vcE "(META-INF|^$)" || echo "0")

  if [ "$diffCount" -eq 0 ]; then
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

  # Check git signatures
  echo ""
  echo "Checking git signatures..."
  tagInfo=$(git for-each-ref "refs/tags/$tag")
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
  echo "Cleaning up..."
  rm -rf $fromPlayFolder $workDir $fromBuildUnzipped $fromPlayUnzipped
  # Cleanup Docker resources
  $CONTAINER_CMD rm -f unstoppable-container 2>/dev/null || true
  $CONTAINER_CMD rmi unstoppable-build -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
  # Remove temporary Dockerfile
  rm -f unstoppable.dockerfile
}

# Main execution
echo "Starting Unstoppable Wallet verification..."
echo "This process may take 45-90 minutes depending on your system."
echo "Note: This build requires 12GB memory allocation."
echo

prepare
echo "Repository prepared. Starting build..."

test_unstoppable
echo "Build completed. Running comparison..."

result
echo "Verification completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "Unstoppable Wallet verification finished!"