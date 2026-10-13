#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/tests/fixtures/srm-portal-delayed-form.html" "$WORK/portal.html"
cp "$ROOT/tests/fixtures/srm-portal-missing-handler.html" "$WORK/missing.html"
cp "$ROOT/tests/fixtures/srm-portal-untrusted-redirect.html" "$WORK/redirect.html"
cp "$ROOT/tests/fixtures/srm-portal-access-granted.html" "$WORK/granted.html"
printf '<html><body><h1>Untrusted destination</h1><input type="password"></body></html>' > "$WORK/untrusted.html"
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import sys, uuid
root, work = map(Path, sys.argv[1:])
src = (root/'App/AutoConnectManager.swift').read_text()
# Only external boundaries change: local fixture URL, trust for that exact local
# URL, isolated defaults and shorter watchdogs. Window/lifecycle/script stay real.
src = src.replace('https://iac.srmist.edu.in/Connect/PortalMain', (work/'portal.html').as_uri())
start = src.index('    private func isTrustedPortalURL(')
end = src.index('\n    // MARK: - Credential injection', start)
src = src[:start] + '    private func isTrustedPortalURL(_ url: URL?) -> Bool { url == portalCandidates.first }\n' + src[end:]
src = src.replace('loginFormTimeout: TimeInterval = 25', 'loginFormTimeout: TimeInterval = 4')
src = src.replace('self.after(3, token)', 'self.after(0.1, token)')
src = src.replace('UserDefaults.standard', f'UserDefaults(suiteName: "PortalWindowTest-{uuid.uuid4()}")!')
src += '\nextension AutoConnectManager { var portalWindowForTest: NSWindow { hostWindow }; var portalBrowserForTest: WKWebView { webView } }\n'
(work/'AutoConnectManager.swift').write_text(src)
PY
SOURCES=("$WORK/AutoConnectManager.swift" "$ROOT/tests/PortalWindowHarness.swift")
if [ -f "$ROOT/App/PortalLoginView.swift" ]; then SOURCES+=("$ROOT/App/PortalLoginView.swift"); fi
swiftc -module-cache-path "$WORK/module-cache" -target "$(uname -m)-apple-macosx13.0" "${SOURCES[@]}" -o "$WORK/harness"
"$WORK/harness" "$WORK" "${1:-$WORK/preview.png}"
