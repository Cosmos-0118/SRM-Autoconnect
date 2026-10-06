using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using SRMAutoconnect.Core;

internal static class Program
{
    private const BindingFlags PrivateInstance = BindingFlags.NonPublic | BindingFlags.Instance;

    [STAThread]
    private static int Main()
    {
        // Keep test browser state inside ignored build output, away from the app.
        var stateDir = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../build/windows-regression-state"));
        Directory.CreateDirectory(stateDir);
        Environment.SetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER", stateDir);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var exitCode = 1;
        app.Startup += async (_, _) =>
        {
            try
            {
                await RunAsync();
                exitCode = 0;
            }
            catch (Exception ex) { Console.Error.WriteLine(ex); }
            finally
            {
                AutoConnectManager.Shared.Dispose();
                app.Shutdown();
            }
        };
        app.Run();
        return exitCode;
    }

    private static async Task RunAsync()
    {
        var manager = AutoConnectManager.Shared;
        await (Task)typeof(AutoConnectManager).GetMethod("EnsureWebViewAsync", PrivateInstance)!
            .Invoke(manager, [CancellationToken.None])!;
        var view = (WebView2)typeof(AutoConnectManager).GetField("webView", PrivateInstance)!.GetValue(manager)!;
        view.CoreWebView2.SetVirtualHostNameToFolderMapping("iac.srmist.edu.in",
            Path.Combine(AppContext.BaseDirectory, "fixtures"), CoreWebView2HostResourceAccessKind.Deny);

        string fixture = "srm-portal.html";
        view.CoreWebView2.NavigationStarting += (_, e) =>
        {
            if (e.Uri == "https://iac.srmist.edu.in/Connect/PortalMain")
            {
                e.Cancel = true;
                view.CoreWebView2.Navigate("https://iac.srmist.edu.in/" + fixture);
            }
            else if (!e.Uri.StartsWith("https://iac.srmist.edu.in/", StringComparison.Ordinal))
            {
                e.Cancel = true; // No real campus login or external navigation.
            }
        };
        var messages = new List<string>();
        view.CoreWebView2.WebMessageReceived += (_, e) => messages.Add(e.WebMessageAsJson);

        ReachabilityProbe.Shared.IsOnline = async () =>
        {
            var result = await view.CoreWebView2.ExecuteScriptAsync("!!window.__formSubmitted");
            return result == "true";
        };

        foreach (var name in new[] { "srm-portal.html", "portal-jsbutton.html", "srm-portal-delayed-handler.html" })
        {
            fixture = name;
            await ClearPageAsync(view);
            messages.Clear();
            ReachabilityProbe.Shared.Reset();
            var elapsed = Stopwatch.StartNew();
            manager.AttemptLogin(); // Exercise the automatic entry point.
            await UntilAsync(() => !manager.IsConnecting, TimeSpan.FromSeconds(35));
            Check(manager.LastResult == LoginResult.Success, name + ": automatic login verifies internet");
            Check(elapsed.Elapsed < TimeSpan.FromSeconds(15), name + ": does not wait for a visible AJAX response");
            using var fields = JsonDocument.Parse(await view.CoreWebView2.ExecuteScriptAsync("JSON.stringify(Array.from(document.querySelectorAll('input')).map(x=>({id:x.id,type:x.type,value:x.value})))"));
            using var values = JsonDocument.Parse(fields.RootElement.GetString()!);
            var inputs = values.RootElement.EnumerateArray().ToArray();
            Check(inputs.Any(x => x.GetProperty("type").GetString() == "password" && x.GetProperty("value").GetString() == "fixture-password"), name + ": correct password field");
            Check(inputs.Any(x => x.GetProperty("type").GetString() == "text" && x.GetProperty("value").GetString() == "fixture-user"), name + ": username remains intact");
            Check(messages.Any(x => x.Contains("submitted")), name + ": submission message received");
            Check(ReachabilityProbe.Shared.Calls >= 2, name + ": success requires a post-submit probe");
            Check(await view.CoreWebView2.ExecuteScriptAsync("window.__earlyClicks || 0") == "0", name + ": no premature click");
        }

        // Hold NavigationCompleted until after the document-created script has
        // submitted. This reproduces the original overwritten-task race.
        fixture = "srm-portal.html";
        await ClearPageAsync(view);
        var handler = (EventHandler<CoreWebView2NavigationCompletedEventArgs>)Delegate.CreateDelegate(
            typeof(EventHandler<CoreWebView2NavigationCompletedEventArgs>), manager,
            typeof(AutoConnectManager).GetMethod("HandleNavigationCompleted", PrivateInstance)!);
        view.CoreWebView2.NavigationCompleted -= handler;
        CoreWebView2NavigationCompletedEventArgs? deferredNavigation = null;
        EventHandler<CoreWebView2NavigationCompletedEventArgs> defer = (_, e) => { if (e.IsSuccess) deferredNavigation = e; };
        view.CoreWebView2.NavigationCompleted += defer;
        messages.Clear();
        manager.AttemptLogin();
        await UntilAsync(() => messages.Any(x => x.Contains("submitted")), TimeSpan.FromSeconds(10));
        Check(deferredNavigation is not null, "early-submit: initial navigation was deferred");
        handler(view.CoreWebView2, deferredNavigation!);
        await UntilAsync(() => !manager.IsConnecting, TimeSpan.FromSeconds(10));
        Check(manager.LastResult == LoginResult.Success, "early-submit: initial message survives outcome-task replacement");
        view.CoreWebView2.NavigationCompleted -= defer;
        view.CoreWebView2.NavigationCompleted += handler;

        fixture = "srm-portal-throwing-handler.html";
        await ClearPageAsync(view);
        messages.Clear();
        var failures = manager.TotalFailures;
        manager.AttemptLogin(force: true);
        await UntilAsync(() => !manager.IsConnecting, TimeSpan.FromSeconds(10));
        Check(manager.TotalFailures == failures + 1, "throwing handler: attempt fails");
        Check(!messages.Any(x => x.Contains("submitted")), "throwing handler: no false submission");
        Check(!messages.Any(x => x.Contains("s3cr3t") || x.Contains("AN1234")), "throwing handler: exception secrets are redacted");
        Check(await view.CoreWebView2.ExecuteScriptAsync("window.__clicked.length") == "0", "throwing handler: no fallback click");
        manager.CancelAutomaticLoginForNetworkChange();

        fixture = "srm-portal-missing-handler.html";
        await ClearPageAsync(view);
        manager.AttemptLogin();
        await UntilAsync(() => !manager.IsConnecting, TimeSpan.FromSeconds(35));
        Check(manager.LastFailureReason?.Contains("handler") == true || manager.LastFailureReason?.Contains("ready") == true,
            "missing handler: bounded failure");
        Check(await view.CoreWebView2.ExecuteScriptAsync("window.__earlyClicks") == "0", "missing handler: never bypasses SRM encryption flow");
        manager.CancelAutomaticLoginForNetworkChange();

        fixture = "srm-portal-rejected.html";
        await ClearPageAsync(view);
        messages.Clear();
        manager.AttemptLogin();
        await UntilAsync(() => !manager.IsConnecting, TimeSpan.FromSeconds(10));
        Check(manager.LastFailureReason?.Contains("rejected") == true, "rejected credentials: stops verification and retries");
        Check(!messages.Any(x => x.Contains("Invalid password fixture-password")), "rejected credentials: response text stays out of messages");
        manager.CancelAutomaticLoginForNetworkChange();

        fixture = "srm-portal.html";
        await ClearPageAsync(view);
        ReachabilityProbe.Shared.IsOnline = () => Task.FromResult(false);
        ReachabilityProbe.Shared.Reset();
        manager.AttemptLogin();
        await UntilAsync(() => !manager.IsConnecting, TimeSpan.FromSeconds(30));
        Check(manager.LastFailureReason?.Contains("still intercepting") == true,
            "submission alone: never reports success without internet");
        Check(ReachabilityProbe.Shared.Calls == 9, "submission alone: verification has a bounded retry budget");
        manager.CancelAutomaticLoginForNetworkChange();

        NetworkMonitor.Shared.IsReadyForAutomaticLogin = false;
        manager.AttemptLogin();
        Check(!manager.IsConnecting, "automatic login pauses off a ready SRM network");
        NetworkMonitor.Shared.IsReadyForAutomaticLogin = true;
        fixture = "srm-portal-delayed-handler.html";
        await ClearPageAsync(view);
        manager.AttemptLogin();
        manager.CancelAutomaticLoginForReadinessLoss();
        await Task.Delay(200);
        Check(!manager.IsConnecting && manager.NextAttemptAt is null, "readiness loss cancels login and retry");

        Console.WriteLine("ALL WINDOWS REGRESSIONS PASS (real WebView2; fake credentials; controlled reachability)");
    }

    private static async Task ClearPageAsync(WebView2 view)
    {
        // Force a clean document before the next preflight probe.
        var completion = new TaskCompletionSource();
        EventHandler<CoreWebView2NavigationCompletedEventArgs>? handler = null;
        handler = (_, _) => { view.CoreWebView2.NavigationCompleted -= handler; completion.TrySetResult(); };
        view.CoreWebView2.NavigationCompleted += handler;
        view.CoreWebView2.Navigate("https://iac.srmist.edu.in/empty.html");
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(10));
    }

    private static async Task UntilAsync(Func<bool> predicate, TimeSpan timeout)
    {
        var elapsed = Stopwatch.StartNew();
        while (!predicate())
        {
            if (elapsed.Elapsed > timeout) throw new TimeoutException("Fixture exceeded " + timeout);
            await Task.Delay(50);
        }
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException("FAIL: " + description);
        Console.WriteLine("PASS: " + description);
    }
}
