#!/bin/bash
# verify_app.zeusln.zeus.sh v1.0.1 - Standalone verification script for Zeus Lightning Network wallet
# Usage: verify_app.zeusln.zeus.sh -a path/to/zeus.apk [-r revisionOverride] [-n] [-c] [-x]

set -e

# Display disclaimer at start of script
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Running this script grants it access to your"
echo "connected Android device and may modify system files."
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
extractFromPhone=false
bundletoolPath=""

# Detect available container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
else
    echo -e "${RED}Error: Neither podman nor docker found. Please install one of them.${NC}"
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m' # No Color

# Zeus-specific constants
repo=https://github.com/ZeusLN/zeus
BUILDER_IMAGE="docker.io/reactnativecommunity/react-native-android@sha256:6607421944d844b82e4d05df50c11dc9fa455108222d63475cd3a0f62465fbda"

# Helper functions
# ===============

# Function to check if a command exists and print status
check_command() {
  if command -v $1 &> /dev/null || alias | grep -q "$1"; then
    echo -e "$1 - ${GREEN}✓ installed${NC}"
  else
    echo -e "$1 - ${RED}[x] not installed${NC}"
    MISSING_DEPENDENCIES=true
  fi
}

is_app_installed() {
  local package_name="$1"
  if adb shell pm list packages | grep -q "^package:$package_name$"; then
    return 0 # App is installed
  else
    return 1 # App is not installed
  fi
}

get_version_code() {
  local apk_path="$1"
  aapt dump badging "$apk_path" | grep versionCode | awk '{print $3}' | sed "s/versionCode='//" | sed "s/'//"
}

get_full_apk_name() {
  local package_name="$1"
  local apk_path=$(adb shell pm path "$package_name" | grep "base.apk" | cut -d':' -f2 | tr -d '\r')
  if [ -z "$apk_path" ]; then
    echo "Error: Could not find base.apk for $package_name" >&2
    return 1
  fi
  local apk_name=$(adb shell ls -l "$apk_path" | awk '{print $NF}')
  echo "$apk_name"
}

# Check if bundletool is installed
check_bundletool() {
  echo "Checking for bundletool in /usr/local/lib and /usr/share/java..."
  if [ -f "/usr/local/lib/bundletool.jar" ]; then
    bundletoolPath="/usr/local/lib/bundletool.jar"
    echo -e "bundletool - ${GREEN}✓ installed${NC}"
    echo "Bundletool location: /usr/local/lib/bundletool.jar"
  elif [ -f "/usr/share/java/bundletool.jar" ]; then
    bundletoolPath="/usr/share/java/bundletool.jar"
    echo -e "bundletool - ${GREEN}✓ installed${NC}"
    echo "Bundletool location: /usr/share/java/bundletool.jar"
  else
    echo "Checking for bundletool alias in ~/.bashrc..."
    if grep -q "alias bundletool=" ~/.bashrc; then
      bundletoolPath=$(grep "alias bundletool=" ~/.bashrc | sed -e "s/alias bundletool='//" -e "s/'$//")
      echo -e "bundletool - ${GREEN}✓ installed${NC}"
      echo "Bundletool alias found in ~/.bashrc"
      echo "Bundletool location: $bundletoolPath"
    else
      echo -e "bundletool - ${RED}[x] not installed${NC}"
      echo "Please ensure bundletool is installed and available in your PATH."
      MISSING_DEPENDENCIES=true
    fi
  fi
}

extract_apk_from_phone() {
  local bundleId="app.zeusln.zeus"

  echo -e "${YELLOW}████████████████ PHONE EXTRACTION MODE ████████████████${NC}"
  echo -e "${YELLOW}Ensure that phone is plugged with the zeus app installed.${NC}"
  echo -e "${YELLOW}Or if you prefer to download it yourself, pass -a /path/to/zeus.apk.${NC}"
  echo -e "${YELLOW}If -x is passed, the script runs built-in APK extraction, downloads the APK${NC}"
  echo -e "${YELLOW}to your computer and performs the verification on the APK.${NC}"
  echo

  MISSING_DEPENDENCIES=false

  # Check dependencies
  check_command "adb"
  check_command "java"
  check_command "aapt"
  check_bundletool

  if [ "$MISSING_DEPENDENCIES" = true ]; then
    echo -e "${RED}Please install the missing dependencies before running the script.${NC}"
    exit 1
  fi

  # Check if a phone is connected
  connected_devices=$(adb devices | grep -w "device")
  if [ -z "$connected_devices" ]; then
    echo -e "${RED}████████████████ No phone is connected. Exiting program ████████████████${NC}"
    echo
    echo -e "${YELLOW}To connect your phone:${NC}"
    echo -e "${YELLOW}1. Plug your Android phone into this computer via USB cable${NC}"
    echo -e "${YELLOW}2. Enable Developer Options on your phone (Settings > About Phone > tap Build Number 7 times)${NC}"
    echo -e "${YELLOW}3. Enable USB Debugging (Settings > Developer Options > USB Debugging)${NC}"
    echo -e "${YELLOW}4. Grant permissions when prompted on your phone${NC}"
    echo -e "${YELLOW}5. Ensure Zeus Lightning Network wallet is installed on your device${NC}"
    exit 1
  else
    echo -e "${GREEN}Device connected successfully.${NC}"
    echo "Device information:"
    adb devices
    echo "Model: $(adb shell getprop ro.product.model)"
    echo "Manufacturer: $(adb shell getprop ro.product.manufacturer)"
    echo "Android Version: $(adb shell getprop ro.build.version.release)"
    echo "SDK Version: $(adb shell getprop ro.build.version.sdk)"
  fi

  # Check if the app is installed
  if ! is_app_installed "$bundleId"; then
    echo -e "${RED}Error: The app '$bundleId' is not installed on the connected device.${NC}"
    exit 1
  fi

  # Get APK paths
  echo "Retrieving APK paths for bundle ID: $bundleId"
  apks=$(adb shell pm path $bundleId)

  echo "APK paths retrieved:"
  echo "$apks"

  # Determine if the app uses single or split APKS
  if echo "$apks" | grep -qE "split_|config."; then
    echo -e "${YELLOW}████████████████ $bundleId - uses split APKs ████████████████${NC}"
  else
    echo -e "${YELLOW}████████████████ $bundleId - uses single APK ████████████████${NC}"
  fi

  # Create temporary directory for APKs
  local temp_dir="/tmp/test_app.zeusln.zeus_$(date +%s)"
  mkdir -p "$temp_dir/official-apk"

  # Pull APKs
  echo "Pulling APKs..."
  for apk in $apks; do
    apkPath=$(echo $apk | awk '{print $NF}' FS=':' | tr -d '\r\n')
    echo "Pulling $apkPath"
    adb pull "$apkPath" "$temp_dir/official-apk/"
  done

  # Set downloadedApk to the base.apk
  downloadedApk="$temp_dir/official-apk/base.apk"

  echo "APK extracted to: $downloadedApk"
}

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
  # The folder with the apk file is mounted read only and only the output folder
  # is mounted with write permission.
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
      echo -e "${YELLOW}Or install docker: sudo apt install docker.io${NC}"
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
       verify_app.zeusln.zeus.sh - verify Zeus Lightning Network wallet build

SYNOPSIS
       verify_app.zeusln.zeus.sh -a downloadedApk [-r revisionOverride] [-n] [-c]
       verify_app.zeusln.zeus.sh -x [-r revisionOverride] [-n] [-c]

DESCRIPTION
       This command tries to verify builds of Zeus Lightning Network wallet.

       -a|--apk The apk file we want to test.
       -x|--extract Extract APK from connected phone
       -r|--revision-override git revision id to use if tag is not found
       -n|--not-interactive The script will not ask for user actions
       -c|--cleanup Clean up temporary files after testing'
}

# Read script arguments and flags
# ===============================

while [[ "$#" -gt 0 ]]; do
  case $1 in
    -a|--apk) downloadedApk="$2"; shift ;;
    -x|--extract) extractFromPhone=true ;;
    -r|--revision-override) revisionOverride="$2"; shift ;;
    -n|--not-interactive) takeUserActionCommand='' ;;
    -c|--cleanup) shouldCleanup=true ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

# Handle phone extraction or validate APK file
if [ "$extractFromPhone" = true ]; then
  # We'll extract metadata after pulling from phone
  extract_apk_from_phone
else
  # Validate inputs
  if [ ! -f "$downloadedApk" ]; then
    echo "APK file not found!"
    echo
    usage
    exit 1
  fi
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

# Verify this is Zeus
if [ "$appId" != "app.zeusln.zeus" ]; then
  echo "This script is only for Zeus Lightning Network wallet (app.zeusln.zeus)"
  echo "Detected appId: $appId"
  exit 1
fi

# If we extracted from phone, rename the temp directory with proper version info
if [ "$extractFromPhone" = true ]; then
  old_temp_dir=$(dirname "$downloadedApk")
  new_temp_dir="/tmp/test_app.zeusln.zeus.sh_${versionName}"

  if [ "$old_temp_dir" != "$new_temp_dir" ]; then
    mv "$old_temp_dir" "$new_temp_dir"
    downloadedApk="$new_temp_dir/official-apk/base.apk"
    echo "Renamed temp directory to: $new_temp_dir"
  fi

  # Keep workDir separate from the official APK directory
  # workDir is used for building, not for the official APK location
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Zeus-specific logic
# ==================

tag=v$versionName
case $(($versionCode % 10)) in
  1) architecture="armeabi-v7a" ;;
  2) architecture="x86" ;;
  3) architecture="arm64-v8a" ;;
  4) architecture="x86_64" ;;
  *) echo "Invalid version code ending, please provide a version code ending in 1, 2, 3, or 4." >&2; exit 1 ;;
esac
builtApk="$workDir/app/android/app/build/outputs/apk/release/zeus-$architecture.apk"

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

test_zeus() {
  # Zeus-specific build logic
  CONTAINER_NAME="zeus_builder_container_$(date +%s)"
  ZEUS_PATH=/olympus/zeus

  echo "Cleaning any previous build artifacts..."
  rm -rf android/app/build/ || true
  rm -rf node_modules/ || true

  # Run the container command
  $CONTAINER_CMD run --rm --name $CONTAINER_NAME -v "$(pwd):$ZEUS_PATH" $BUILDER_IMAGE bash -c \
       'echo -e "\n\n********************************\n*** Building ZEUS...\n********************************\n" && \
        cd /olympus/zeus && \
        yarn install --frozen-lockfile && \
        yarn cache clean --force && \
        cd android && \
        ./gradlew clean && \
        ./gradlew app:assembleRelease --no-daemon --stacktrace && \

        echo -e "\n\n********************************\n**** APKs and SHA256 Hashes\n********************************\n" && \
        cd /olympus/zeus && \
        for f in android/app/build/outputs/apk/release/*.apk;
        do
	        RENAMED_FILENAME=$(echo $f | sed -e "s/app-/zeus-/" | sed -e "s/-release-unsigned//")
	        mv $f $RENAMED_FILENAME
	        sha256sum $RENAMED_FILENAME
        done && \
        echo -e "\n" ';
}

result() {
  set +x
  # collect results
  fromPlayUnzipped=/tmp/fromPlay_${appId}_$versionCode
  fromBuildUnzipped=/tmp/fromBuild_${appId}_$versionCode
  rm -rf $fromBuildUnzipped $fromPlayUnzipped
  unzip -d $fromPlayUnzipped -qq "$downloadedApk" || exit 1
  unzip -d $fromBuildUnzipped -qq "$builtApk" || exit 1
  
  # Run diff and capture result
  diffResult=$( diff --brief --recursive $fromPlayUnzipped $fromBuildUnzipped 2>/dev/null || true )
  
  # Filter out expected Google Play Store differences
  filteredDiff=$(echo "$diffResult" | grep -vE "(META-INF|stamp-cert-sha256|AndroidManifest\.xml)" || true)
  
  # Count remaining differences
  if [[ "$filteredDiff" =~ ^[[:space:]]*$ ]]; then
    diffCount=0
  else
    diffCount=$(echo "$filteredDiff" | grep -c "." 2>/dev/null || echo "0")
  fi
  
  # Determine verdict based on filtered differences
  verdict=""
  if [[ "$diffCount" =~ ^[0-9]+$ ]] && [ "$diffCount" -eq 0 ]; then
    verdict="reproducible"
  else
    verdict="not reproducible"
  fi

  # Prepare diff guide
  diffGuide=""
  if [ "$shouldCleanup" != true ]; then
    diffGuide="
For detailed analysis, run:
  diff --recursive $fromPlayUnzipped $fromBuildUnzipped
  meld $fromPlayUnzipped $fromBuildUnzipped
  diffoscope \"$downloadedApk\" $builtApk"
  fi

  # Additional info handling
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
verdict:        $verdict
appHash:        $appHash
commit:         $commit

Diff (Google Play distribution files excluded):
$filteredDiff

Full Diff (including expected Google Play files):
$diffResult

Revision, tag (and its signature):"

  # Determine if tag is annotated or lightweight
  tagInfo=$(git for-each-ref "refs/tags/$tag" 2>/dev/null || echo "")
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

  # Final status message
  if [ "$verdict" = "reproducible" ]; then
    echo -e "\n${GREEN}✓ Verification completed - Zeus wallet is reproducible!${NC}"
  else
    echo -e "\n${RED}✗ Verification completed with differences${NC}"
  fi
}

cleanup() {
  echo "Cleaning up temporary files..."
  rm -rf $fromPlayFolder $workDir $fromBuildUnzipped $fromPlayUnzipped
  # Additional container cleanup
  $CONTAINER_CMD rmi zeus_builder -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
# =============

echo "Starting Zeus Lightning Network wallet verification process..."
echo "This process may take 10-30 minutes depending on your system."
echo

prepare
echo "Preparation completed. Starting build..."

test_zeus
echo "Build completed. Starting comparison..."

result
echo "Comparison completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "Zeus verification completed!"