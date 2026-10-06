import WebKit
import AppKit

// Runs the production script against local HTML with fake credentials only.
final class Harness: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: WKWebView!
    var window: NSWindow!
    var reports: [[String: Any]] = []
    let dir = CommandLine.arguments[1]
    private var activityToken: NSObjectProtocol?
    private var injected = false
    private var inspecting = false

    func fail(_ reason: String) -> Never { print("FAIL:", reason); exit(1) }

    func applicationDidFinishLaunching(_ n: Notification) {
        activityToken = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Local WebKit regression test")
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { self.fail("harness deadline exceeded") }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "srm")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        webView.loadFileURL(URL(fileURLWithPath: dir + "/portal.html"), allowingReadAccessTo: URL(fileURLWithPath: dir))
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        guard !injected else { return }; injected = true
        guard let js = try? String(contentsOfFile: dir + "/injected.js", encoding: .utf8), !js.isEmpty else {
            fail("missing injected script")
        }
        w.evaluateJavaScript(js) { _, err in if let err { self.fail("injection error: \(err)") } }
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        fail("fixture navigation failed")
    }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any] else { fail("malformed report") }
        reports.append(b)
        if ["waitinghandler", "handlerready"].contains(b["stage"] as? String ?? "") { return }
        guard !inspecting else { return }; inspecting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.inspect() }
    }
    func inspect() {
        let probe = """
        (function() {
          var user = document.querySelector('input[type="text"], input[type="email"], input[type="tel"]');
          var pass = document.querySelector('input[type="password"]');
          return JSON.stringify({user: user ? user.value : '', pass: pass ? pass.value : '',
            clicked: window.__clicked || [], handlerCalled: !!window.__handlerCalled,
            submitted: !!window.__formSubmitted, earlyClicks: window.__earlyClicks || 0,
            handlerCalls: window.__handlerCalls, expectedStage: window.__expectedStage || 'submitted'});
        })()
        """
        webView.evaluateJavaScript(probe) { result, error in
            guard error == nil, let s = result as? String, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                self.fail("inspection returned no valid JSON")
            }
            var passed = true
            func check(_ name: String, _ ok: Bool) {
                print("[\(ok ? "PASS" : "FAIL")] \(name)"); if !ok { passed = false }
            }
            let expected = o["expectedStage"] as? String ?? "submitted"
            let terminal = self.reports.filter { !["waitinghandler", "handlerready"].contains($0["stage"] as? String ?? "") }
            check("exactly one terminal report", terminal.count == 1)
            check("expected stage \(expected)", terminal.first?["stage"] as? String == expected)
            let clicked = o["clicked"] as? [String] ?? []
            if expected == "submitted" {
                check("username filled", o["user"] as? String == "AN1234")
                check("password filled", o["pass"] as? String == "s3cr3t")
                check("real submit path", (clicked.contains("BUTTON#btnSubmit") || o["handlerCalled"] as? Bool == true) && !clicked.contains("INPUT#loginId"))
                check("actually submitted", o["submitted"] as? Bool == true)
                if let count = o["handlerCalls"] as? Int { check("handler invoked once", count == 1) }
            } else {
                check("no successful submission", o["submitted"] as? Bool == false)
                check("no fallback click", clicked.isEmpty)
                if let count = o["handlerCalls"] as? Int {
                    check("bounded handler dispatch", count == (expected == "submiterror" ? 1 : 0))
                }
            }
            check("no early click", o["earlyClicks"] as? Int == 0)
            check("safe report details", self.reports.allSatisfy {
                let detail = $0["detail"] as? String ?? ""
                return !detail.contains("AN1234") && !detail.contains("s3cr3t") && !detail.contains("?secret")
            })
            print(passed ? "ALL PASS" : "FAILURES"); exit(passed ? 0 : 1)
        }
    }
}
let app = NSApplication.shared
let h = Harness()
app.delegate = h
app.setActivationPolicy(.accessory)
app.run()
