#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT" "$WORK" "${1:-$ROOT/App/AutoConnectManager.swift}" <<'PY_EXTRACT'
from pathlib import Path
import re, sys
root, work, source = map(Path, sys.argv[1:])
src=source.read_text()
methods=[]
for name in ['userContentController','verify','isLive','after','finish','redacted']:
    m=re.search(r'    (?:private )?func '+name+r'\(.*?\n    }\n',src,re.S)
    if not m: raise SystemExit('Missing production method: '+name)
    methods.append(m.group(0))
m=re.search(r'    private func transition\(.*?\n    }\n',src,re.S)
if m: methods.append(m.group(0))
template=(root/'tests/VerificationHarness.swift').read_text()
watchdog=re.search(r'        after\(loginFormTimeout, token\) \{.*?\n        }\n',src,re.S)
if not watchdog: raise SystemExit('Missing production form watchdog')
(work/'Harness.swift').write_text(template.replace('    // __PRODUCTION_METHODS__',''.join(methods)).replace('        // __FORM_WATCHDOG__',watchdog.group(0)))
PY_EXTRACT
swiftc -module-cache-path "$WORK/module-cache" -target "$(uname -m)-apple-macosx13.0" "$ROOT/App/ReachabilityProbe.swift" "$WORK/Harness.swift" -o "$WORK/harness"
"$WORK/harness"
