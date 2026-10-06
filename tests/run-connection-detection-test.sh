#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -module-cache-path "$WORK/module-cache" -target "$(uname -m)-apple-macosx13.0" "$ROOT/App/ReachabilityProbe.swift" "$ROOT/App/ConnectionDetectionPolicy.swift" "$ROOT/App/NetworkMonitor.swift" "$ROOT/tests/ConnectionDetectionHarness.swift" -o "$WORK/harness"
"$WORK/harness"
