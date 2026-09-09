#!/bin/bash
# ==============================================================================
# macSCP Local Build Script
# Builds macSCP using the 'macSCP (Local)' scheme and 'Local' configuration
# (Ad-hoc signing / Sign to Run Locally - no Apple Developer Team needed).
# ==============================================================================

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="macSCP"
SCHEME="macSCP (Local)"
CONFIGURATION="Local"
OUTPUT_DIR="${PROJECT_DIR}/build"

INSTALL=false
OPEN_APP=false

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --install|-i)
            INSTALL=true
            ;;
        --open|-o)
            OPEN_APP=true
            ;;
        --help|-h)
            echo "Usage: ./build-local.sh [options]"
            echo ""
            echo "Options:"
            echo "  --install, -i   Copy built app to /Applications"
            echo "  --open, -o      Open the app immediately after building"
            echo "  --help, -h      Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./build-local.sh --help for options."
            exit 1
            ;;
    esac
done

echo "🚀 Building ${APP_NAME} locally (Scheme: '${SCHEME}', Config: '${CONFIGURATION}')..."

if command -v xcpretty >/dev/null 2>&1; then
    xcodebuild build \
        -project "${PROJECT_DIR}/macSCP.xcodeproj" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" | xcpretty
else
    xcodebuild build \
        -project "${PROJECT_DIR}/macSCP.xcodeproj" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}"
fi

# Locate the built product
BUILD_SETTINGS=$(xcodebuild -project "${PROJECT_DIR}/macSCP.xcodeproj" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -showBuildSettings 2>/dev/null)
BUILT_PRODUCTS_DIR=$(echo "${BUILD_SETTINGS}" | grep -E '^[[:space:]]*BUILT_PRODUCTS_DIR =' | head -1 | awk -F' = ' '{print $2}')
FULL_PRODUCT_NAME=$(echo "${BUILD_SETTINGS}" | grep -E '^[[:space:]]*FULL_PRODUCT_NAME =' | head -1 | awk -F' = ' '{print $2}')

if [ -z "${FULL_PRODUCT_NAME}" ]; then
    FULL_PRODUCT_NAME="${APP_NAME}.app"
fi

APP_SOURCE="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"

if [ ! -d "${APP_SOURCE}" ]; then
    echo "❌ Build product not found at: ${APP_SOURCE}"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/${FULL_PRODUCT_NAME}"
cp -R "${APP_SOURCE}" "${OUTPUT_DIR}/"

LOCAL_APP="${OUTPUT_DIR}/${FULL_PRODUCT_NAME}"
echo ""
echo "✅ Build succeeded!"
echo "📍 App bundle copied to: ${LOCAL_APP}"

if [ "${INSTALL}" = true ]; then
    echo "📦 Installing to /Applications/${FULL_PRODUCT_NAME}..."
    rm -rf "/Applications/${FULL_PRODUCT_NAME}"
    cp -R "${LOCAL_APP}" "/Applications/"
    echo "✨ Installed successfully to /Applications/${FULL_PRODUCT_NAME}"
fi

if [ "${OPEN_APP}" = true ]; then
    TARGET_TO_OPEN="${LOCAL_APP}"
    if [ "${INSTALL}" = true ]; then
        TARGET_TO_OPEN="/Applications/${FULL_PRODUCT_NAME}"
    fi
    echo "🎉 Launching ${TARGET_TO_OPEN}..."
    open "${TARGET_TO_OPEN}"
fi
