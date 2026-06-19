#!/bin/bash
# @title Version Bump Script
# @description Bumps version in module.prop.
#              Format: vMAJOR.MINOR.PATCH with versionCode = MAJOR*10000 + MINOR*100 + PATCH

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_PROP="${SCRIPT_DIR}/../../module.prop"

BUMP_TYPE="${1:-build}"

# Read current version
CURRENT_VERSION=$(grep '^version=' "${MODULE_PROP}" | cut -d= -f2 | sed 's/^v//')
IFS='.' read -r MAJOR MINOR PATCH <<< "${CURRENT_VERSION}"
MAJOR=${MAJOR:-0}
MINOR=${MINOR:-0}
PATCH=${PATCH:-0}

echo "Current version: v${MAJOR}.${MINOR}.${PATCH}"

# Bump
case "${BUMP_TYPE}" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  build) PATCH=$((PATCH + 1)) ;;
  none)  echo "No version bump."; exit 0 ;;
  *)     echo "Unknown bump type: ${BUMP_TYPE}"; exit 1 ;;
esac

NEW_VERSION="v${MAJOR}.${MINOR}.${PATCH}"
# versionCode: simple integer (no leading zeros)
NEW_VERSION_CODE=$((MAJOR * 10000 + MINOR * 100 + PATCH))

echo "New version: ${NEW_VERSION} (${NEW_VERSION_CODE})"

# Update module.prop
sed -i "s|^version=.*|version=${NEW_VERSION}|" "${MODULE_PROP}"
sed -i "s|^versionCode=.*|versionCode=${NEW_VERSION_CODE}|" "${MODULE_PROP}"

# Update update.json
UPDATE_JSON="${SCRIPT_DIR}/../../update.json"
if [ -f "${UPDATE_JSON}" ]; then
  sed -i "s|\"version\".*|\"version\": \"${NEW_VERSION}\",|" "${UPDATE_JSON}"
  sed -i "s|\"versionCode\".*|\"versionCode\": \"${NEW_VERSION_CODE}\",|" "${UPDATE_JSON}"
fi

echo "Version bumped to ${NEW_VERSION} (${NEW_VERSION_CODE})"
