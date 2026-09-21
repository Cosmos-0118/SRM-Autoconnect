"""Static checks for the Windows portal injection script and macOS handler order."""
from __future__ import annotations

import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
cs = (root / "windows/SRMAutoconnect/Core/AutoConnectManager.cs").read_text(encoding="utf-8")
match = re.search(
    r'private static string BuildInjectionScript.*?return \$\$"""\n(.*)\n        """;',
    cs,
    re.S,
)
if not match:
    sys.exit("Could not extract Windows injection script.")
js = match.group(1)

first_visible = js.split("function firstVisible", 1)[1].split("function ", 1)[0]
handler_pos = js.find("handler();")
click_pos = js.find("btn.click()")
find_password = js.split("function findPassword", 1)[1].split("function ", 1)[0]

checks = {
    "firstVisible returns null not nodes[0]": (
        "return nodes.length ? nodes[0] : null;" not in first_visible
        and "return null;" in first_visible
    ),
    "handler before click": handler_pos > 0 and click_pos > handler_pos,
    "findSubmit scoped to ownerDoc": (
        "function findSubmit(scope, ownerDoc)" in js
        and "if (ownerDoc && ownerDoc !== scope) roots.push(ownerDoc)" in js
        and "if (scope !== document) roots.push(document)" not in js
    ),
    "readyState gate": "document.readyState !== 'complete'" in js,
    "requires cpRSAobj": "function rsaReady()" in js and "if (!rsaReady()" in js,
    "stable two ticks": "if (readyTicks < 2) return;" in js,
    "discover log": "report('discover'" in js,
    "accepted outcome": "report('accepted'" in js,
    "rejected outcome": "report('rejected'" in js,
    "noresponse outcome": "report('noresponse'" in js,
    "no iframe recursion in findPassword": "contentDocument" not in find_password,
}

swift = (root / "App/AutoConnectManager.swift").read_text(encoding="utf-8")
sm = re.search(r'let js = """\n(.*)\n        """', swift, re.S)
if not sm:
    sys.exit("Could not extract macOS injection script.")
sjs = sm.group(1)
checks["macOS still handler-first"] = (
    "oAuthentication.submitActiveForm" in sjs
    and sjs.find("oAuthentication.submitActiveForm") < sjs.find("btn.click()")
)

failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), name)
if failed:
    sys.exit("FAILED: " + ", ".join(failed))
print(f"ALL INVARIANTS PASS, windows script {len(js)} chars")
