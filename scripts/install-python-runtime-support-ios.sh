#!/bin/sh
set -e

source "$PROJECT_DIR/Frameworks/Python-iOS.xcframework/build/utils.sh"

has_python_origin_marker() {
  framework_dir="$1"
  for origin_marker in "$framework_dir"/*.origin; do
    if [ -f "$origin_marker" ]; then
      return 0
    fi
  done
  return 1
}

cleanup_generated_python_extension_frameworks() {
  frameworks_dir="$CODESIGNING_FOLDER_PATH/Frameworks"
  if [ ! -d "$frameworks_dir" ]; then
    return 0
  fi

  for framework_dir in "$frameworks_dir"/*.framework; do
    if [ ! -d "$framework_dir" ]; then
      continue
    fi
    if has_python_origin_marker "$framework_dir"; then
      echo "Removing stale generated Python extension framework: ${framework_dir##*/}"
      rm -rf "$framework_dir"
    fi
  done
}

validate_generated_python_extension_frameworks() {
  frameworks_dir="$CODESIGNING_FOLDER_PATH/Frameworks"
  if [ ! -d "$frameworks_dir" ]; then
    return 0
  fi

  for framework_dir in "$frameworks_dir"/*.framework; do
    if [ ! -d "$framework_dir" ]; then
      continue
    fi
    if has_python_origin_marker "$framework_dir"; then
      plist="$framework_dir/Info.plist"
      package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist" 2>/dev/null || true)"
      if [ "$package_type" != "FMWK" ]; then
        echo "error: Generated Python extension framework has CFBundlePackageType=$package_type: $framework_dir"
        exit 1
      fi
    fi
  done
}

sign_generated_python_extension_frameworks() {
  frameworks_dir="$CODESIGNING_FOLDER_PATH/Frameworks"
  if [ ! -d "$frameworks_dir" ]; then
    return 0
  fi

  if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] || [ "${CODE_SIGNING_REQUIRED:-YES}" = "NO" ]; then
    echo "Skipping generated Python extension framework signing because code signing is disabled."
    return 0
  fi

  sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
  if [ -z "$sign_identity" ]; then
    echo "error: No code signing identity is available for generated Python extension frameworks."
    exit 1
  fi

  for framework_dir in "$frameworks_dir"/*.framework; do
    if [ ! -d "$framework_dir" ]; then
      continue
    fi
    if has_python_origin_marker "$framework_dir"; then
      echo "Signing generated Python extension framework: ${framework_dir##*/}"
      /usr/bin/codesign --force --sign "$sign_identity" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none --generate-entitlement-der "$framework_dir"
      if ! /usr/bin/codesign --verify --strict --verbose=2 "$framework_dir"; then
        echo "error: Generated Python extension framework failed code signature verification: $framework_dir"
        exit 1
      fi
      if [ ! -d "$framework_dir/_CodeSignature" ]; then
        echo "error: Generated Python extension framework has no code signature: $framework_dir"
        exit 1
      fi
    fi
  done
}

cleanup_generated_python_extension_frameworks
install_python "Frameworks/Python-iOS.xcframework"
validate_generated_python_extension_frameworks
sign_generated_python_extension_frameworks
mkdir -p "$CODESIGNING_FOLDER_PATH/python"
touch "$CODESIGNING_FOLDER_PATH/python/.noema-python-runtime-stamp"
