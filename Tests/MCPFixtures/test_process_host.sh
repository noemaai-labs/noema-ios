#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/noema-mcp-process-host-tests"
/usr/bin/clang -std=c17 -Wall -Wextra \
  "$ROOT/Tests/MCPFixtures/process_host_harness.c" \
  "$ROOT/NoemaMCPHost/MCPProcessSpawn.c" \
  -o "$OUT"
"$OUT"
