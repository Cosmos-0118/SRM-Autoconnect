// Regression harness for the credential-injection script. Driven by
// tests/run-injection-test.sh, which substitutes __FIXTURE_DIR__ and extracts
// the real script out of App/AutoConnectManager.swift before running this.
//
// What it guards: the script must fill both fields and then click an element
// that is actually clickable. Several of the button selectors match text inputs
// just as readily as buttons, and a username field with id="loginId" is
// completely ordinary on a portal — so the selector walk once picked the field
// it had just typed the username into, never submitted the form, and leaked
// that username into the log file via the report detail.
import WebKit
import AppKit

// Loads a portal-shaped page in a real WKWebView and runs the ACTUAL injected
// script extracted from AutoConnectManager.swift, then reports which control it
// clicked and whether the fields were filled.
final class Harness: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: WKWebView!
    var window: NSWindow!
    var reports: [[String: Any]] = []
    let dir = "__FIXTURE_DIR__"

    func applicationDidFinishLaunching(_ n: Notification) {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "srm")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        webView.loadFileURL(URL(fileURLWithPath: dir + "/portal.html"),
                            allowingReadAccessTo: URL(fileURLWithPath: dir))
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        let js = (try? String(contentsOfFile: dir + "/injected.js", encoding: .utf8)) ?? ""
        w.evaluateJavaScript(js) { _, err in
            if let err { print("INJECTION ERROR:", err); NSApp.terminate(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { self.inspect() }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if let b = m.body as? [String: Any] { reports.append(b) }
    }

    func inspect() {
        let probe = """
        (function() {
          var user = document.querySelector('input[type="text"], input[type="email"], input[type="tel"]');
          var pass = document.querySelector('input[type="password"]');
        JSON.stringify({
          user: user ? user.value : '',
          pass: pass ? pass.value : '',
          clicked: window.__clicked || [],
          handlerCalled: !!window.__handlerCalled,
          submitted: !!window.__formSubmitted
        })
        })()
        """
        webView.evaluateJavaScript(probe) { result, _ in
            print("=== script reports ===")
            for r in self.reports { print("  ", r) }
            print("=== page state ===")
            print("  ", result ?? "nil")
            var pass = true
            if let s = result as? String, let d = s.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let user = o["user"] as? String ?? ""
                let pw = o["pass"] as? String ?? ""
                let clicked = o["clicked"] as? [String] ?? []
                let handlerCalled = o["handlerCalled"] as? Bool ?? false
                print("\n=== assertions ===")
                func check(_ name: String, _ cond: Bool) {
                    print("  [\(cond ? "PASS" : "FAIL")] \(name)"); if !cond { pass = false }
                }
                check("username field filled", user == "AN1234")
                check("password field filled", pw == "s3cr3t")
                check("used a real submit path, not the username input",
                      (clicked.contains("BUTTON#btnSubmit") || handlerCalled) && !clicked.contains("INPUT#loginId"))
                check("form actually submitted", (o["submitted"] as? Bool) == true)
                let stage = self.reports.first?["stage"] as? String ?? ""
                check("reported stage == submitted (got '\(stage)')", stage == "submitted")
                let detail = self.reports.first?["detail"] as? String ?? ""
                check("report detail leaks no field value (got '\(detail)')",
                      !detail.contains("AN1234") && !detail.contains("s3cr3t"))
            }
            print("\nRESULT:", pass ? "ALL PASS" : "FAILURES")
            exit(pass ? 0 : 1)
        }
    }
}
let app = NSApplication.shared
let h = Harness()
app.delegate = h
app.setActivationPolicy(.accessory)
app.run()
