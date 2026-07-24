#!/bin/sh
set -eu

# Reproducible Apple-Silicon runtime for the notarized Direct edition only.
# The archive's official SHA256 manifest is verified before anything is copied.
NODE_VERSION="${NOEMA_NODE_VERSION:-22.17.1}"
ARCHIVE="node-v${NODE_VERSION}-darwin-arm64.tar.gz"
BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"
CACHE_ROOT="${PROJECT_TEMP_DIR}/noema-mcp-node-v${NODE_VERSION}"
DOWNLOAD_ROOT="${CACHE_ROOT}/download"
EXPANDED_ROOT="${CACHE_ROOT}/expanded"
DESTINATION="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/MCPRuntime"

mkdir -p "${DOWNLOAD_ROOT}" "${EXPANDED_ROOT}"
if [ ! -f "${DOWNLOAD_ROOT}/${ARCHIVE}" ]; then
  /usr/bin/curl --fail --location --retry 3 --output "${DOWNLOAD_ROOT}/${ARCHIVE}" "${BASE_URL}/${ARCHIVE}"
fi
/usr/bin/curl --fail --location --retry 3 --output "${DOWNLOAD_ROOT}/SHASUMS256.txt" "${BASE_URL}/SHASUMS256.txt"

EXPECTED="$(/usr/bin/awk -v archive="${ARCHIVE}" '$2 == archive { print $1; exit }' "${DOWNLOAD_ROOT}/SHASUMS256.txt")"
ACTUAL="$(/usr/bin/shasum -a 256 "${DOWNLOAD_ROOT}/${ARCHIVE}" | /usr/bin/awk '{ print $1 }')"
if [ -z "${EXPECTED}" ] || [ "${EXPECTED}" != "${ACTUAL}" ]; then
  echo "error: Node runtime checksum validation failed for ${ARCHIVE}" >&2
  exit 1
fi

rm -rf "${EXPANDED_ROOT}" "${DESTINATION}"
mkdir -p "${EXPANDED_ROOT}" "${DESTINATION}"
/usr/bin/tar -xzf "${DOWNLOAD_ROOT}/${ARCHIVE}" -C "${EXPANDED_ROOT}" --strip-components=1
/usr/bin/ditto "${EXPANDED_ROOT}/bin" "${DESTINATION}/bin"
/usr/bin/ditto "${EXPANDED_ROOT}/lib/node_modules" "${DESTINATION}/lib/node_modules"

# npm and npx are small launch scripts whose interpreter resolves to the signed
# bundled node binary. Sign Mach-O code explicitly before the enclosing app.
chmod 755 "${DESTINATION}/bin/node" "${DESTINATION}/bin/npm" "${DESTINATION}/bin/npx"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
  /usr/bin/codesign --force --timestamp=none --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "${DESTINATION}/bin/node"
fi
/usr/bin/touch "${DESTINATION}/.noema-node-runtime-${NODE_VERSION}"
