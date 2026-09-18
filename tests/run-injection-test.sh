#!/bin/bash
# Regression test for the credential-injection script in AutoConnectManager.swift.
#
# The injected JavaScript is the least testable and most failure-prone part of
# this app: it runs inside a page we do not control, on a network we cannot
# reach from a developer's desk, and when it picks the wrong element the app
# reports "credentials likely rejected" — blaming the user's password for its
# own bug. That is precisely the failure this test exists to catch.
#
# The script under test is EXTRACTED FROM THE SWIFT SOURCE rather than copied,
# so this test cannot silently drift away from what actually ships.
#
# Usage: ./tests/run-injection-test.sh
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Extracting the injected script from App/AutoConnectManager.swift..."
python3 - "$ROOT" "$WORK" <<'PY'
import re, sys, os
root, work = sys.argv[1], sys.argv[2]
src = open(os.path.join(root, 'App/AutoConnectManager.swift')).read()
m = re.search(r'let js = """\n(.*?)\n        """', src, re.S)
if not m:
    sys.exit("Could not find the injected script literal. Did injectLogin() change shape?")
js = m.group(1)
# Stand in for the Swift string interpolations.
js = js.replace('\\(token)', '1')
js = js.replace('\\(jsLiteral(creds.username))', '"AN1234"')
js = js.replace('\\(jsLiteral(creds.password))', '"s3cr3t"')
open(os.path.join(work, 'injected.js'), 'w').write(js)
print(f"  extracted {len(js)} chars")
PY

run_fixture() {
  local fixture="$1"
  local fixture_dir="$WORK/$fixture"
  mkdir -p "$fixture_dir"
  cp "$ROOT/tests/fixtures/$fixture.html" "$fixture_dir/portal.html"
  cp "$WORK/injected.js" "$fixture_dir/injected.js"

  echo "Building harness for $fixture..."
  sed "s#__FIXTURE_DIR__#$fixture_dir#g" "$ROOT/tests/InjectionHarness.swift" > "$fixture_dir/main.swift"
  swiftc -target "$(uname -m)-apple-macosx13.0" "$fixture_dir/main.swift" -o "$fixture_dir/harness"

  echo "Running $fixture..."
  "$fixture_dir/harness"
}

run_fixture portal-jsbutton
run_fixture srm-portal
