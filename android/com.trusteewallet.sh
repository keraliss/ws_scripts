#!/bin/bash

repo=https://github.com/trustee-wallet/trusteeWallet.git
tag="v$versionName"
builtApk=$workDir/app-release.apk

test() {
  # Remove any existing trustee docker image
  podman rmi trustee -f
  
  # Build the Docker image
  podman build \
    --tag trustee \
    --build-arg TAG=$tag \
    --file $SCRIPT_DIR/test/android/com.trusteewallet.dockerfile
  
  # Run the container and build the app
  podman run \
    --volume $workDir:/mnt \
    --rm \
    trustee \
    bash -c "cd /trustee/src && git checkout $tag && cd ./android && ./gradlew --console=plain --parallel assembleRelease && cp /trustee/src/android/app/build/outputs/apk/release/app-release.apk /mnt/ || find /trustee -name '*.apk' -exec cp {} /mnt/ \;"
  
  # Clean up
  podman rmi trustee -f
  podman image prune -f
}