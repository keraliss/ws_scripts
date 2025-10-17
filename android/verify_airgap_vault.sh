#!/bin/bash
# verify_airgap_vault.sh v1.0.0 - Standalone verification script for AirGap Vault
# Combines functionality from test.sh and airgap vault build logic
# Usage: verify_airgap_vault.sh -a path/to/airgap-vault.apk [-r revisionOverride] [-n] [-c]

set -e

# Display disclaimer at start of script
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Running this script grants it access to your"
echo "system and may modify files."
echo "Use at your own risk and ensure you understand what the script does before"
echo "execution."
echo "=============================================================================="
echo -e "\033[0m"
sleep 2
echo

# Global Constants
# ================
wsContainer="docker.io/walletscrutiny/android:5"
takeUserActionCommand='echo "CTRL-D to continue";
  bash'
shouldCleanup=false

# Detect available container runtime
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
else
    echo -e "${RED}Error: Neither docker nor podman found. Please install Docker.${NC}"
    echo "AirGap Vault build requires Docker specifically."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m' # No Color

# AirGap Vault specific constants
repo="https://github.com/airgap-it/airgap-vault"

# Helper functions
# ===============

containerApktool() {
  targetFolder=$1
  app=$2
  targetFolderParent=$(dirname "$targetFolder")
  targetFolderBase=$(basename "$targetFolder")
  appFolder=$(dirname "$app")
  appFile=$(basename "$app")
  
  # Check if APK file exists and is readable
  if [ ! -f "$app" ]; then
    echo -e "${RED}Error: APK file not found: $app${NC}"
    return 1
  fi

  # Run apktool in a container so apktool doesn't need to be installed.
  echo "Running apktool with $CONTAINER_CMD..."
  if ! $CONTAINER_CMD run \
    --rm \
    --volume $targetFolderParent:/tfp \
    --volume $appFolder:/af:ro \
    $wsContainer \
    sh -c "apktool d -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""; then

    echo -e "${RED}Container apktool failed. This might be due to storage issues.${NC}"
    if [ "$CONTAINER_CMD" = "podman" ]; then
      echo -e "${YELLOW}Try running: podman system reset --force${NC}"
    elif [ "$CONTAINER_CMD" = "docker" ]; then
      echo -e "${YELLOW}Try running: docker system prune -f${NC}"
    fi
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
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256"  | awk '{print $6}' )
  echo $s
}

usage() {
  echo 'NAME
       verify_airgap_vault.sh - verify AirGap Vault build

SYNOPSIS
       verify_airgap_vault.sh -a downloadedApk [-r revisionOverride] [-n] [-c]

DESCRIPTION
       This command tries to verify builds of AirGap Vault.

       -a|--apk The apk file we want to test.
       -r|--revision-override git revision id to use if tag is not found
       -n|--not-interactive The script will not ask for user actions
       -c|--cleanup Clean up temporary files after testing'
}

# Read script arguments and flags
# ===============================

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

# make sure path is absolute
if ! [[ $downloadedApk =~ ^/.* ]]; then
  downloadedApk="$PWD/$downloadedApk"
fi

# Extract APK metadata
# ===================

appHash=$(sha256sum "$downloadedApk" | awk '{print $1;}')
fromPlayFolder=/tmp/fromPlay$appHash
rm -rf $fromPlayFolder
signer=$( getSigner "$downloadedApk" )
echo "Extracting APK content ..."
containerApktool $fromPlayFolder "$downloadedApk" || exit 1
appId=$( cat $fromPlayFolder/AndroidManifest.xml | head -n 1 | sed 's/.*package=\"//g' | sed 's/\".*//g' )
versionName=$( cat $fromPlayFolder/apktool.yml | grep versionName | sed 's/.*\: //g' | sed "s/'//g" )
versionCode=$( cat $fromPlayFolder/apktool.yml | grep versionCode | sed 's/.*\: //g' | sed "s/'//g" )
workDir=/tmp/test_$appId

# Validate extracted metadata
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

# Verify this is AirGap Vault
if [ "$appId" != "it.airgap.vault" ]; then
  echo "This script is only for AirGap Vault (it.airgap.vault)"
  echo "Detected appId: $appId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# AirGap Vault specific logic
# ==========================

tag=v$versionName
builtApk=$workDir/app/airgap-vault-release-unsigned.apk

prepare() {
  echo "Testing $appId from $repo revision $tag (revisionOverride: '$revisionOverride')..."
  # cleanup
  rm -rf "$workDir" || exit 1
  # get unique folder
  mkdir -p $workDir
  cd $workDir
  # clone
  echo "Trying to clone …"
  if [ -n "$revisionOverride" ]
  then
    git clone --quiet $repo app && cd app && git checkout "$revisionOverride" || exit 1
  else
    git clone --quiet --branch "$tag" --depth 1 $repo app && cd app || exit 1
  fi
  commit=$( git log -n 1 --pretty=oneline | sed 's/ .*//g' )
}

test_airgap() {
  echo "Starting AirGap Vault build process..."
  
  # AirGap Vault specific build logic - adapted from the provided snippet
  echo "Cleaning up any existing Docker containers and images..."
  docker rmi airgap-vault -f 2>/dev/null || true
  docker rm airgap-vault-build -f 2>/dev/null || true
  docker image prune -f

  echo "Modifying version in build.gradle..."
  # Modify the version in build.gradle to match the APK version
  sed -i -e "s/versionName \"0.0.0\"/versionName \"$versionName\"/g" android/app/build.gradle
  
  echo "Building Docker image for AirGap Vault..."
  echo "This may take several minutes..."
  
  # Build the Docker image with the specific build arguments
  if ! docker build -f build/android/Dockerfile -t airgap-vault \
    --ulimit=nofile=10000:10000 \
    --build-arg BUILD_NR="$versionCode" \
    --build-arg VERSION="$versionName" .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  echo "Running container to complete build..."
  if ! docker run --name "airgap-vault-build" airgap-vault echo "container ran."; then
    echo -e "${RED}Container run failed!${NC}"
    exit 1
  fi
  
  echo "Copying built APK from container..."
  if ! docker cp airgap-vault-build:/app/android-release-unsigned.apk airgap-vault-release-unsigned.apk; then
    echo -e "${RED}Failed to copy APK from container!${NC}"
    exit 1
  fi
  
  echo "Cleaning up Docker resources..."
  docker rmi airgap-vault -f 2>/dev/null || true
  docker rm airgap-vault-build -f 2>/dev/null || true
  docker image prune -f
  
  echo "AirGap Vault build completed successfully!"
  
  # Verify the built APK exists
  if [ ! -f "$builtApk" ]; then
    echo -e "${RED}Error: Built APK not found at expected location: $builtApk${NC}"
    echo "Checking current directory contents:"
    ls -la
    exit 1
  fi
  
  echo -e "${GREEN}Built APK found: $builtApk${NC}"
  echo "APK size: $(ls -lh "$builtApk" | awk '{print $5}')"
}

result() {
  set +x
  echo "Setting up comparison directories..."
  # collect results
  fromPlayUnzipped=/tmp/fromPlay_${appId}_$versionCode
  fromBuildUnzipped=/tmp/fromBuild_${appId}_$versionCode
  rm -rf $fromBuildUnzipped $fromPlayUnzipped
  
  echo "Extracting downloaded APK: $downloadedApk (this may take a few minutes for large APKs...)"
  if ! timeout 300 unzip -d $fromPlayUnzipped -qq "$downloadedApk"; then
    echo -e "${RED}Failed to extract downloaded APK (timeout after 5 minutes or extraction error)${NC}"
    exit 1
  fi
  echo "Downloaded APK extracted successfully"
  
  echo "Extracting built APK: $builtApk (this may take a few minutes for large APKs...)"
  if ! timeout 300 unzip -d $fromBuildUnzipped -qq "$builtApk"; then
    echo -e "${RED}Failed to extract built APK (timeout after 5 minutes or extraction error)${NC}"
    exit 1
  fi
  echo "Built APK extracted successfully"
  
  echo "Running diff comparison (this may take several minutes for large APKs)..."
  echo "Please wait..."
  
  # Use timeout for diff as well, and handle it more carefully
  if timeout 600 diff --brief --recursive $fromPlayUnzipped $fromBuildUnzipped > /tmp/diff_result.txt 2>&1; then
    # No differences found
    diffResult=""
  else
    # Either differences found or timeout - check which
    if [ $? -eq 124 ]; then
      echo -e "${RED}Diff operation timed out after 10 minutes${NC}"
      diffResult="TIMEOUT: Diff operation exceeded 10 minutes"
    else
      # Normal diff with differences found
      diffResult=$(cat /tmp/diff_result.txt)
    fi
  fi
  
  diffCount=$( echo "$diffResult" | grep -vcE "(META-INF|^$|TIMEOUT)" || echo "0" )
  
  echo "Diff comparison completed"

  diffGuide="
Run a full
diff --recursive $fromPlayUnzipped $fromBuildUnzipped
meld $fromPlayUnzipped $fromBuildUnzipped
or
diffoscope \"$downloadedApk\" $builtApk
for more details."
  if [ "$shouldCleanup" = true ]; then
    diffGuide=''
  fi
  if [ "$additionalInfo" ]; then
    additionalInfo="===== Also ====
$additionalInfo
"
  fi
  echo "===== Begin Results =====
appId:          $appId
signer:         $signer
apkVersionName: $versionName
apkVersionCode: $versionCode
appHash:        $appHash
commit:         $commit

Diff:
$diffResult

Revision, tag (and its signature):"

  # Determine if tag is annotated or lightweight
  tagInfo=$(git for-each-ref "refs/tags/$tag")
  isAnnotatedTag=false
  tagType="lightweight"
  if [[ $tagInfo == *"tag"* ]]; then
    isAnnotatedTag=true
    tagType="annotated"
  fi

  # Check signatures
  signatureWarnings=""
  tagSignatureStatus=""
  commitSignatureStatus=""
  signatureKeys=""

  # Try to verify tag signature (will work for annotated tags)
  if $isAnnotatedTag; then
    tagVerification=$(git tag -v "$tag" 2>&1) || true
    echo "$tagVerification"

    if [[ $tagVerification == *"Good signature"* ]]; then
      tagSignatureStatus="✓ Good signature on annotated tag"
      # Extract signing key
      tagKey=$(echo "$tagVerification" | grep "using .* key" | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)
      if [[ ! -z "$tagKey" ]]; then
        signatureKeys="Tag signed with: $tagKey"
      fi
    else
      tagSignatureStatus="⚠️ No valid signature found on annotated tag"
      signatureWarnings="$signatureWarnings\n- Annotated tag exists but is not signed"
    fi
  else
    tagSignatureStatus="ℹ️ Tag is lightweight (cannot contain signature)"
  fi

  # Try to verify commit signature
  commitObj="$tag"
  if $isAnnotatedTag; then
    # For annotated tags, we need to get the commit it points to
    commitObj="$tag^{commit}"
  fi

  commitVerification=$(git verify-commit "$commitObj" 2>&1) || true
  if [[ $commitVerification == *"Good signature"* ]]; then
    commitSignatureStatus="✓ Good signature on commit"
    # Extract signing key
    commitKey=$(echo "$commitVerification" | grep "using .* key" | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)
    if [[ ! -z "$commitKey" ]]; then
      if [[ ! -z "$signatureKeys" ]]; then
        signatureKeys="$signatureKeys\nCommit signed with: $commitKey"
      else
        signatureKeys="Commit signed with: $commitKey"
      fi

      # Compare keys if both tag and commit are signed
      if [[ ! -z "$tagKey" && ! -z "$commitKey" && "$tagKey" != "$commitKey" ]]; then
        signatureWarnings="$signatureWarnings\n- Tag and commit signed with different keys"
      fi
    fi
  else
    commitSignatureStatus="⚠️ No valid signature found on commit"
    if [[ -z "$signatureWarnings" ]]; then
      signatureWarnings="- Commit is not signed"
    else
      signatureWarnings="$signatureWarnings\n- Commit is not signed"
    fi
  fi

  # Output the signature summary
  echo "
Signature Summary:
Tag type: $tagType
$tagSignatureStatus
$commitSignatureStatus"

  if [[ ! -z "$signatureKeys" ]]; then
    echo -e "\nKeys used:
$signatureKeys"
  fi

  if [[ ! -z "$signatureWarnings" ]]; then
    echo -e "\nWarnings:$signatureWarnings"
  fi

  echo -e "\n$additionalInfo===== End Results =====
$diffGuide"
}

cleanup() {
  echo "Cleaning up temporary files..."
  rm -rf $fromPlayFolder $workDir $fromBuildUnzipped $fromPlayUnzipped
  # Additional Docker cleanup
  docker rmi airgap-vault -f 2>/dev/null || true
  docker rm airgap-vault-build -f 2>/dev/null || true
  docker image prune -f 2>/dev/null || true
}

# Main execution
# =============

echo "Starting AirGap Vault verification process..."
echo "This process may take 10-30 minutes depending on your system."
echo

prepare
echo "Preparation completed. Starting build..."

test_airgap
echo "Build completed. Starting comparison..."

result
echo "Comparison completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "AirGap Vault verification completed!"