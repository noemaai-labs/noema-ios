#!/bin/sh
set -eu

echo "Preparing Noema package artifacts for xcodebuild"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

patched_interfaces=0
patched_modulemaps=0

patch_artifact_root() {
  artifact_root="$1"
  if [ ! -d "$artifact_root" ]; then
    return
  fi

  interface_list="$(mktemp)"
  modulemap_list="$(mktemp)"

  find "$artifact_root" \
    \( -path "*/executorch.xcframework/*/ExecuTorch.swiftinterface" \
       -o -path "*/executorch.xcframework/*/Headers/ExecuTorch.swiftinterface" \
       -o -path "*/executorch_debug.xcframework/*/ExecuTorch.swiftinterface" \
       -o -path "*/executorch_debug.xcframework/*/Headers/ExecuTorch.swiftinterface" \) \
    -type f -print > "$interface_list"

  while IFS= read -r interface_path
  do
    disabled_path="$interface_path.xcodecloud-disabled"
    if [ -e "$disabled_path" ]; then
      continue
    fi
    mv "$interface_path" "$disabled_path"
    patched_interfaces=$((patched_interfaces + 1))
    echo "Disabled ExecuTorch Swift interface: $interface_path"
  done < "$interface_list"

  find "$artifact_root" \
    \( -path "*/executorch.xcframework/*/Headers/module.modulemap" \
       -o -path "*/executorch_debug.xcframework/*/Headers/module.modulemap" \) \
    -type f -print > "$modulemap_list"

  while IFS= read -r modulemap_path
  do
    if grep -q "module ExecuTorch {" "$modulemap_path"; then
      tmp_path="$modulemap_path.tmp"
      sed "s/module ExecuTorch {/module ExecuTorch [system] {/" "$modulemap_path" > "$tmp_path"
      mv "$tmp_path" "$modulemap_path"
      patched_modulemaps=$((patched_modulemaps + 1))
      echo "Marked ExecuTorch module map as system: $modulemap_path"
    fi
  done < "$modulemap_list"

  rm -f "$interface_list" "$modulemap_list"
}

if [ -n "${CI_DERIVED_DATA_PATH:-}" ]; then
  patch_artifact_root "$CI_DERIVED_DATA_PATH/SourcePackages/artifacts"
fi
patch_artifact_root "$repo_root/../DerivedData/SourcePackages/artifacts"

echo "ExecuTorch artifact preparation complete: disabled_interfaces=$patched_interfaces system_modulemaps=$patched_modulemaps"
