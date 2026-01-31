#!/bin/bash
# Bull Bitcoin Mobile - Complete Verification Script
# Run each step one by one for testing

set -e

echo "================================================================================"
echo "Bull Bitcoin Mobile - Reproducibility Verification"
echo "================================================================================"
echo ""

# Configuration
WORK_DIR="/home/keraliss/ws_build/bull"
APKS_DIR="/home/keraliss/apks"
DEVICE_APK="${APKS_DIR}/com.bullbitcoin.mobile/official_apks/base.apk"
COMPARE_DIR="/tmp/compare"
REPORT_FILE="${WORK_DIR}/bull_bitcoin_diff_report.txt"

echo "Step 0: Check if Dockerfile exists"
echo "-----------------------------------"
if [ ! -f "${WORK_DIR}/Dockerfile" ]; then
    echo "ERROR: Dockerfile not found at ${WORK_DIR}/Dockerfile"
    exit 1
fi
echo "✓ Dockerfile found"
echo ""

echo "Step 1: Build Docker image"
echo "--------------------------"
cd ${WORK_DIR}
echo "This will take 30-60 minutes on first build..."
echo "Building Bull Bitcoin Docker image..."

# Check if we should use docker or podman
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
else
    echo "ERROR: Neither Docker nor Podman found"
    exit 1
fi

echo "Using: ${CONTAINER_CMD}"

# Build the image
if ! ${CONTAINER_CMD} build -t bullbitcoin-verify:latest -f Dockerfile .; then
    echo "ERROR: Docker build failed!"
    exit 1
fi

echo "✓ Docker image built successfully"
echo ""

echo "Step 2: Extract built APKs from Docker image"
echo "----------------------------------------------"
cd ${WORK_DIR}
echo "Creating temporary container..."
${CONTAINER_CMD} create --name bullbitcoin-temp bullbitcoin-verify:latest
echo "Copying split APKs from container..."
${CONTAINER_CMD} cp bullbitcoin-temp:/app/split-apks ${APKS_DIR}/built
echo "Removing temporary container..."
${CONTAINER_CMD} rm bullbitcoin-temp
echo "✓ Step 2 complete"
echo ""

echo "Step 3: Verify APK files exist"
echo "-------------------------------"
if [ ! -f "${DEVICE_APK}" ]; then
    echo "ERROR: Device APK not found at ${DEVICE_APK}"
    exit 1
fi
if [ ! -f "${APKS_DIR}/built/base-master.apk" ]; then
    echo "ERROR: Built APK not found at ${APKS_DIR}/built/base-master.apk"
    exit 1
fi
echo "✓ Both APK files found"
echo "  Device: ${DEVICE_APK}"
echo "  Built:  ${APKS_DIR}/built/base-master.apk"
echo ""

echo "Step 4: Create comparison directories"
echo "--------------------------------------"
rm -rf ${COMPARE_DIR}
mkdir -p ${COMPARE_DIR}/device
mkdir -p ${COMPARE_DIR}/build
echo "✓ Directories created"
echo ""

echo "Step 5: Extract APKs for comparison"
echo "------------------------------------"
echo "Extracting device APK..."
unzip -q ${DEVICE_APK} -d ${COMPARE_DIR}/device/
echo "Extracting built APK..."
unzip -q ${APKS_DIR}/built/base-master.apk -d ${COMPARE_DIR}/build/
echo "✓ APKs extracted"
echo ""

echo "Step 6: Quick comparison (excluding META-INF)"
echo "----------------------------------------------"
DIFF_OUTPUT=$(diff -r ${COMPARE_DIR}/device ${COMPARE_DIR}/build 2>&1 | grep -v META-INF || true)
DIFF_COUNT=$(echo "$DIFF_OUTPUT" | grep -vcE "^$" || echo "0")

if [ "$DIFF_COUNT" -eq 0 ]; then
    echo "✅ SUCCESS: APKs are REPRODUCIBLE!"
    VERDICT="REPRODUCIBLE"
else
    echo "❌ FAILED: APKs are NOT reproducible - $DIFF_COUNT differences found"
    VERDICT="NOT REPRODUCIBLE"
fi
echo ""

echo "Step 7: Calculate SHA256 hashes"
echo "--------------------------------"
DEVICE_HASH=$(sha256sum ${DEVICE_APK} | awk '{print $1}')
BUILT_HASH=$(sha256sum ${APKS_DIR}/built/base-master.apk | awk '{print $1}')
echo "Device APK SHA256: ${DEVICE_HASH}"
echo "Built APK SHA256:  ${BUILT_HASH}"
echo ""

echo "Step 8: Generate detailed diff report"
echo "--------------------------------------"

# Start report
cat > ${REPORT_FILE} << EOF
================================================================================
Bull Bitcoin Mobile - Reproducibility Verification Report
================================================================================
Date: $(date)
App ID: com.bullbitcoin.mobile
Device APK: ${DEVICE_APK}
Built APK: ${APKS_DIR}/built/base-master.apk

SHA256 Hashes:
- Device: ${DEVICE_HASH}
- Built:   ${BUILT_HASH}

Verdict: ${VERDICT}
================================================================================

DETAILED DIFFERENCES:

1. BINARY FILE DIFFERENCES:
----------------------------
EOF

# Add binary file differences
diff -r ${COMPARE_DIR}/device ${COMPARE_DIR}/build 2>&1 | grep "^Binary files" | grep -v META-INF >> ${REPORT_FILE} || true

# Files only in device
cat >> ${REPORT_FILE} << EOF

2. FILES ONLY IN DEVICE APK:
----------------------------
EOF
diff -r ${COMPARE_DIR}/device ${COMPARE_DIR}/build 2>&1 | grep "^Only in ${COMPARE_DIR}/device" | grep -v META-INF >> ${REPORT_FILE} || true

# Files only in build
cat >> ${REPORT_FILE} << EOF

3. FILES ONLY IN BUILT APK:
---------------------------
EOF
diff -r ${COMPARE_DIR}/device ${COMPARE_DIR}/build 2>&1 | grep "^Only in ${COMPARE_DIR}/build" | grep -v META-INF >> ${REPORT_FILE} || true

# .env differences
cat >> ${REPORT_FILE} << EOF

4. TEXT FILE DIFFERENCES (.env):
--------------------------------
EOF
if [ -f "${COMPARE_DIR}/device/assets/flutter_assets/.env" ] && [ -f "${COMPARE_DIR}/build/assets/flutter_assets/.env" ]; then
    diff -u ${COMPARE_DIR}/device/assets/flutter_assets/.env ${COMPARE_DIR}/build/assets/flutter_assets/.env >> ${REPORT_FILE} 2>&1 || true
else
    echo "Note: .env file not found in one or both APKs" >> ${REPORT_FILE}
fi

# Directory structures
cat >> ${REPORT_FILE} << EOF

5. DIRECTORY STRUCTURE COMPARISON:
-----------------------------------
Device APK structure:
EOF
find ${COMPARE_DIR}/device -type f | grep -v META-INF | sort >> ${REPORT_FILE}

cat >> ${REPORT_FILE} << EOF

Built APK structure:
EOF
find ${COMPARE_DIR}/build -type f | grep -v META-INF | sort >> ${REPORT_FILE}

# File sizes
cat >> ${REPORT_FILE} << EOF

6. FILE SIZE COMPARISON:
------------------------
Device APK total size: $(du -sh ${DEVICE_APK} | awk '{print $1}')
Built APK total size: $(du -sh ${APKS_DIR}/built/base-master.apk | awk '{print $1}')

================================================================================
END OF REPORT
================================================================================
EOF

echo "✓ Report generated: ${REPORT_FILE}"
echo ""

echo "Step 9: Display summary"
echo "-----------------------"
head -20 ${REPORT_FILE}
echo ""
echo "Full report saved to: ${REPORT_FILE}"
echo ""

echo "Step 10: Additional analysis commands"
echo "-------------------------------------"
echo "To view full diff report:"
echo "  cat ${REPORT_FILE}"
echo ""
echo "To use diffoscope for detailed binary analysis:"
echo "  diffoscope ${DEVICE_APK} ${APKS_DIR}/built/base-master.apk"
echo ""
echo "To inspect specific files:"
echo "  diff -u ${COMPARE_DIR}/device/<file> ${COMPARE_DIR}/build/<file>"
echo ""
echo "To compare classes.dex:"
echo "  hexdump -C ${COMPARE_DIR}/device/classes.dex | head -50"
echo "  hexdump -C ${COMPARE_DIR}/build/classes.dex | head -50"
echo ""

echo "================================================================================"
echo "Verification Complete!"
echo "================================================================================"
echo "Result: ${VERDICT}"
echo "Report: ${REPORT_FILE}"
echo "================================================================================"