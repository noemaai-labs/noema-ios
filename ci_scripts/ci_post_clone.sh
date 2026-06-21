#!/bin/sh
set -eu

echo "Preparing Noema dependencies for Xcode Cloud"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

llama_server_url="$(git config --file .gitmodules --get submodule.External/NoemaLLamaServer.url || true)"

if [ -n "${NOEMA_LLAMA_SERVER_REPOSITORY_URL:-}" ]; then
  echo "Using NOEMA_LLAMA_SERVER_REPOSITORY_URL for External/NoemaLLamaServer"
  git config submodule.External/NoemaLLamaServer.url "$NOEMA_LLAMA_SERVER_REPOSITORY_URL"
elif [ -z "$llama_server_url" ] || [ "${llama_server_url#/}" != "$llama_server_url" ] || [ "${llama_server_url#../}" != "$llama_server_url" ] || [ "${llama_server_url#./}" != "$llama_server_url" ]; then
  cat >&2 <<'EOF'
External/NoemaLLamaServer is configured with a local filesystem submodule URL.
Xcode Cloud needs a network-accessible repository URL for that submodule.

Fix one of these before running a release workflow:
1. Update .gitmodules so External/NoemaLLamaServer points at its GitHub remote.
2. Set NOEMA_LLAMA_SERVER_REPOSITORY_URL in the Xcode Cloud workflow environment.
EOF
  exit 1
fi

git submodule sync --recursive
git submodule update --init --recursive

for required_path in \
  "External/NoemaLLamaServer/Package.swift" \
  "External/NoemaWhisperBinary/Package.swift" \
  "External/coreai-models/Package.swift" \
  "Noema.xcodeproj/xcshareddata/xcschemes/Noema.xcscheme" \
  "Noema.xcodeproj/xcshareddata/xcschemes/NoemaMac.xcscheme" \
  "Noema.xcodeproj/xcshareddata/xcschemes/NoemaVisionOS.xcscheme"
do
  if [ ! -e "$required_path" ]; then
    echo "Missing required release dependency: $required_path" >&2
    exit 1
  fi
done

echo "Noema Xcode Cloud dependencies are present"
