using System.ComponentModel;
using System.Text;
using System.Text.Json;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace SRMAutoconnect.Core;

public enum LoginResult
{
    Success,
    AlreadyOnline,
    Failure
}

public sealed class AutoConnectManager : INotifyPropertyChanged, IDisposable
{
    public static AutoConnectManager Shared { get; } = new();

    private static readonly Uri PortalUrl = new("https://iac.srmist.edu.in/Connect/PortalMain");
    private static readonly HashSet<string> TrustedPortalHosts = new(StringComparer.OrdinalIgnoreCase) { "iac.srmist.edu.in" };
    private static readonly TimeSpan[] NetworkNotReadyDelays = [TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(3)];
    private static readonly TimeSpan[] RetryDelays = [TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(8), TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(45)];
    private static readonly TimeSpan[] GiveUpCooldowns = [TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(3), TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(10)];

    private const int PortalNavigationTimeoutSeconds = 18;
    private const int LoginFormTimeoutSeconds = 25;
    private const int AttemptHardTimeoutSeconds = 120;

    private Window? hostWindow;
    private WebView2? webView;
    private bool webMessageHandlerAttached;
    private TaskCompletionSource<ScriptMessage>? scriptMessageCompletion;
    private CancellationTokenSource? currentAttemptCts;
    private int currentAttempt;
    private int retryScheduleGeneration;
    private int retryCount;
    private int networkNotReadyRetries;
    private int consecutiveGiveUps;
    private bool sawNetworkNotReadyInAttempt;
    private bool currentAttemptWasForced;
    private AttemptPhase attemptPhase = AttemptPhase.Idle;

    private int totalSuccesses;
    private int totalFailures;
    private DateTime? lastConnectedTime;
    private bool isConnecting;
    private DateTime? nextAttemptAt;
    private LoginResult? lastResult;
    private string? lastFailureReason;

    public event PropertyChangedEventHandler? PropertyChanged;

    private enum AttemptPhase
    {
        Idle,
        Preflight,
        LoadingPortal,
        WaitingForLoginForm,
        Verifying
    }

    public int TotalSuccesses
    {
        get => totalSuccesses;
        private set => SetField(ref totalSuccesses, value, nameof(TotalSuccesses));
    }

    public int TotalFailures
    {
        get => totalFailures;
        private set => SetField(ref totalFailures, value, nameof(TotalFailures));
    }

    public DateTime? LastConnectedTime
    {
        get => lastConnectedTime;
        private set => SetField(ref lastConnectedTime, value, nameof(LastConnectedTime));
    }

    public bool IsConnecting
    {
        get => isConnecting;
        private set => SetField(ref isConnecting, value, nameof(IsConnecting));
    }

    public DateTime? NextAttemptAt
    {
        get => nextAttemptAt;
        private set => SetField(ref nextAttemptAt, value, nameof(NextAttemptAt));
    }

    public LoginResult? LastResult
    {
        get => lastResult;
        private set => SetField(ref lastResult, value, nameof(LastResult));
    }

    public string? LastFailureReason
    {
        get => lastFailureReason;
        private set => SetField(ref lastFailureReason, value, nameof(LastFailureReason));
    }

    public string CurrentPhase => attemptPhase.ToString();

    private AutoConnectManager()
    {
    }

    public void AttemptLogin(bool force = false)
    {
        RunOnDispatcher(() => _ = StartLoginAsync(force, knownReachability: null));
    }

    public void AttemptLoginAfterConfirmedOutage(Reachability reachability)
    {
        RunOnDispatcher(() => _ = StartLoginAsync(force: false, knownReachability: reachability));
    }

    public void CancelAutomaticLoginForNetworkChange()
    {
        RunOnDispatcher(() =>
        {
            CancelCurrentAttempt("Left SRMIST - cancelled portal login in progress.");
            retryScheduleGeneration++;
            NextAttemptAt = null;
            retryCount = 0;
            networkNotReadyRetries = 0;
            consecutiveGiveUps = 0;
        });
    }

    public void CancelAutomaticLoginForReadinessLoss()
    {
        RunOnDispatcher(() =>
        {
            if (currentAttemptWasForced && IsConnecting)
            {
                return;
            }

            CancelCurrentAttempt("Network readiness was lost - cancelled automatic portal login in progress.");
            retryScheduleGeneration++;
            NextAttemptAt = null;
        });
    }

    public void CancelPendingRetryForWake()
    {
        RunOnDispatcher(() =>
        {
            CancelCurrentAttempt("System resumed - cancelled stale portal login attempt.");
            if (NextAttemptAt is not null || retryCount > 0 || networkNotReadyRetries > 0)
            {
                retryScheduleGeneration++;
                NextAttemptAt = null;
                retryCount = 0;
                networkNotReadyRetries = 0;
                Logger.Shared.Debug("System resumed - discarded retry timer and reset retry ladder.");
            }
        });
    }

    public void CredentialsChanged()
    {
        RunOnDispatcher(() =>
        {
            retryScheduleGeneration++;
            NextAttemptAt = null;
            retryCount = 0;
            networkNotReadyRetries = 0;
            consecutiveGiveUps = 0;
            LastResult = null;
            LastFailureReason = null;
            Logger.Shared.Debug("Credentials changed - cleared backoff.");
            if (NetworkMonitor.Shared.IsConnectedToSRM)
            {
                AttemptLogin();
            }
        });
    }

    public void Dispose()
    {
        currentAttemptCts?.Cancel();
        currentAttemptCts?.Dispose();
        webView?.Dispose();
        hostWindow?.Close();
    }

    private async Task StartLoginAsync(bool force, Reachability? knownReachability)
    {
        if (IsConnecting)
        {
            Logger.Shared.Debug("Login already in flight - ignoring trigger.");
            return;
        }

        if (!force && !NetworkMonitor.Shared.IsReadyForAutomaticLogin)
        {
            Logger.Shared.Debug("SRMIST network is not ready - skipping automatic portal login.");
            return;
        }

        if (force)
        {
            retryScheduleGeneration++;
            NextAttemptAt = null;
            retryCount = 0;
            networkNotReadyRetries = 0;
            consecutiveGiveUps = 0;
        }
        else if (NextAttemptAt is { } until && until > DateTime.Now)
        {
            Logger.Shared.Debug($"Backing off for another {(int)(until - DateTime.Now).TotalSeconds}s - skipping trigger.");
            return;
        }

        Credentials? credentials;
        try
        {
            credentials = ReadCredentials();
        }
        catch (Exception ex)
        {
            Logger.Shared.Log($"Cannot read saved credentials: {ex.Message}");
            ReportBlocked("credentials unreadable - open Settings");
            return;
        }

        if (credentials is null)
        {
            Logger.Shared.Log("Credentials not set - open Settings and save your SRM ID and password.");
            ReportBlocked("no credentials saved - open Settings");
            return;
        }

        currentAttempt++;
        var token = currentAttempt;
        sawNetworkNotReadyInAttempt = false;
        currentAttemptWasForced = force;
        attemptPhase = AttemptPhase.Preflight;
        IsConnecting = true;
        NextAttemptAt = null;
        LastResult = null;
        LastFailureReason = null;

        currentAttemptCts?.Dispose();
        currentAttemptCts = new CancellationTokenSource(TimeSpan.FromSeconds(AttemptHardTimeoutSeconds));

        try
        {
            var reachability = knownReachability ?? await ReachabilityProbe.Shared.ProbeReachabilityAsync(currentAttemptCts.Token);
            EnsureLive(token);

            if (reachability.Online)
            {
                Logger.Shared.Debug("Internet already reachable - no portal login needed.");
                Finish(token);
                retryCount = 0;
                networkNotReadyRetries = 0;
                consecutiveGiveUps = 0;
                ShowResult(LoginResult.AlreadyOnline);
                return;
            }

            Logger.Shared.Log(reachability.CaptivePortal
                ? "Captive portal detected. Logging in..."
                : $"No internet ({reachability.Detail}). Starting portal login...");

            await LoadPortalAndSubmitAsync(token, credentials, currentAttemptCts.Token);
        }
        catch (OperationCanceledException)
        {
            if (IsLive(token))
            {
                await FailAsync(token, $"attempt timed out after {AttemptHardTimeoutSeconds}s");
            }
        }
        catch (Exception ex)
        {
            if (IsLive(token))
            {
                await FailAsync(token, ex.Message);
            }
        }
    }

    private async Task LoadPortalAndSubmitAsync(int token, Credentials credentials, CancellationToken cancellationToken)
    {
        attemptPhase = AttemptPhase.LoadingPortal;
        await EnsureWebViewAsync();
        EnsureLive(token);

        var navigation = await NavigateAsync(PortalUrl, cancellationToken);
        EnsureLive(token);

        if (!navigation.Success)
        {
            if (navigation.NetworkNotReady)
            {
                sawNetworkNotReadyInAttempt = true;
            }

            throw new InvalidOperationException($"portal unreachable - {navigation.Detail}");
        }

        if (!IsTrustedPortalUrl(webView?.Source))
        {
            throw new InvalidOperationException("portal redirected outside the trusted HTTPS SRM portal");
        }

        attemptPhase = AttemptPhase.WaitingForLoginForm;
        var scriptMessage = await InjectLoginAsync(token, credentials, cancellationToken);
        EnsureLive(token);

        switch (scriptMessage.Stage)
        {
            case "submitted":
                attemptPhase = AttemptPhase.Verifying;
                Logger.Shared.Debug($"Credentials submitted via '{scriptMessage.Detail}'. Verifying...");
                await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
                await VerifyAsync(token, remaining: 5, cancellationToken);
                break;
            case "already":
                attemptPhase = AttemptPhase.Verifying;
                Logger.Shared.Debug("Portal reports an existing session. Verifying...");
                await VerifyAsync(token, remaining: 3, cancellationToken);
                break;
            case "nofields":
                throw new InvalidOperationException($"login form never appeared ({scriptMessage.Detail})");
            case "nosubmit":
                throw new InvalidOperationException("no submit button on the login form");
            default:
                throw new InvalidOperationException($"login script reported unexpected stage '{scriptMessage.Stage}'");
        }
    }

    private async Task EnsureWebViewAsync()
    {
        if (webView?.CoreWebView2 is not null)
        {
            return;
        }

        hostWindow ??= new Window
        {
            Width = 1,
            Height = 1,
            Left = -10000,
            Top = -10000,
            ShowInTaskbar = false,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            Opacity = 0
        };

        webView ??= new WebView2 { Width = 1, Height = 1 };
        hostWindow.Content = webView;
        if (!hostWindow.IsVisible)
        {
            hostWindow.Show();
        }

        await webView.EnsureCoreWebView2Async();
        webView.CoreWebView2.Settings.AreDevToolsEnabled = false;
        webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;

        if (!webMessageHandlerAttached)
        {
            webView.CoreWebView2.WebMessageReceived += HandleWebMessageReceived;
            webMessageHandlerAttached = true;
        }
    }

    private async Task<NavigationResult> NavigateAsync(Uri url, CancellationToken cancellationToken)
    {
        if (webView?.CoreWebView2 is null)
        {
            throw new InvalidOperationException("WebView2 is not ready.");
        }

        var completion = new TaskCompletionSource<NavigationResult>(TaskCreationOptions.RunContinuationsAsynchronously);

        void Completed(object? sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            var detail = e.IsSuccess ? "loaded" : e.WebErrorStatus.ToString();
            var notReady = e.WebErrorStatus is CoreWebView2WebErrorStatus.Disconnected
                or CoreWebView2WebErrorStatus.HostNameNotResolved
                or CoreWebView2WebErrorStatus.ConnectionAborted
                or CoreWebView2WebErrorStatus.ConnectionReset
                or CoreWebView2WebErrorStatus.Timeout;
            completion.TrySetResult(new NavigationResult(e.IsSuccess, detail, notReady));
        }

        webView.CoreWebView2.NavigationCompleted += Completed;
        try
        {
            Logger.Shared.Debug($"Loading portal: {url}");
            webView.CoreWebView2.Navigate(url.ToString());
            var finished = await Task.WhenAny(
                completion.Task,
                Task.Delay(TimeSpan.FromSeconds(PortalNavigationTimeoutSeconds), cancellationToken));

            if (finished != completion.Task)
            {
                webView.CoreWebView2.Stop();
                return new NavigationResult(false, $"navigation timed out after {PortalNavigationTimeoutSeconds}s", NetworkNotReady: false);
            }

            return await completion.Task;
        }
        finally
        {
            webView.CoreWebView2.NavigationCompleted -= Completed;
        }
    }

    private async Task<ScriptMessage> InjectLoginAsync(int token, Credentials credentials, CancellationToken cancellationToken)
    {
        if (webView?.CoreWebView2 is null)
        {
            throw new InvalidOperationException("WebView2 is not ready.");
        }

        scriptMessageCompletion = new TaskCompletionSource<ScriptMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        await webView.CoreWebView2.ExecuteScriptAsync(BuildInjectionScript(token, credentials));

        var finished = await Task.WhenAny(
            scriptMessageCompletion.Task,
            Task.Delay(TimeSpan.FromSeconds(LoginFormTimeoutSeconds), cancellationToken));

        if (finished != scriptMessageCompletion.Task)
        {
            throw new InvalidOperationException($"login form did not become ready after {LoginFormTimeoutSeconds}s");
        }

        return await scriptMessageCompletion.Task;
    }

    private async Task VerifyAsync(int token, int remaining, CancellationToken cancellationToken)
    {
        while (remaining > 0)
        {
            EnsureLive(token);
            var reachability = await ReachabilityProbe.Shared.ProbeReachabilityAsync(cancellationToken);
            if (reachability.Online)
            {
                Succeed(token);
                return;
            }

            remaining--;
            if (remaining > 0)
            {
                await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
            }
            else
            {
                await FailAsync(token, reachability.CaptivePortal
                    ? $"portal still intercepting - credentials likely rejected ({reachability.Detail})"
                    : $"no internet after login ({reachability.Detail})");
            }
        }
    }

    private void HandleWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var json = JsonDocument.Parse(e.WebMessageAsJson);
            var root = json.RootElement;
            var attempt = root.GetProperty("attempt").GetInt32();
            if (attempt != currentAttempt || !IsConnecting)
            {
                return;
            }

            var stage = root.GetProperty("stage").GetString() ?? string.Empty;
            var detail = root.TryGetProperty("detail", out var detailElement)
                ? detailElement.GetString() ?? string.Empty
                : string.Empty;
            scriptMessageCompletion?.TrySetResult(new ScriptMessage(stage, detail));
        }
        catch (Exception ex)
        {
            Logger.Shared.Debug($"Could not parse WebView2 script message: {ex.Message}");
        }
    }

    private Task FailAsync(int token, string reason)
    {
        if (!IsLive(token))
        {
            return Task.CompletedTask;
        }

        Finish(token);
        TotalFailures++;
        LastFailureReason = reason;

        if (sawNetworkNotReadyInAttempt && networkNotReadyRetries < NetworkNotReadyDelays.Length)
        {
            var delay = NetworkNotReadyDelays[networkNotReadyRetries] + TimeSpan.FromMilliseconds(Random.Shared.Next(0, 500));
            networkNotReadyRetries++;
            Logger.Shared.Log($"Network not ready yet ({reason}). Retrying in {(int)delay.TotalSeconds}s ({networkNotReadyRetries}/{NetworkNotReadyDelays.Length}).");
            ScheduleRetry(delay);
            return Task.CompletedTask;
        }

        if (retryCount < RetryDelays.Length)
        {
            var delay = RetryDelays[retryCount] + TimeSpan.FromMilliseconds(Random.Shared.Next(0, 1500));
            retryCount++;
            Logger.Shared.Log($"Login failed ({reason}). Retry {retryCount}/{RetryDelays.Length} in {(int)delay.TotalSeconds}s.");
            ScheduleRetry(delay);
            return Task.CompletedTask;
        }

        var cooldown = GiveUpCooldowns[Math.Min(consecutiveGiveUps, GiveUpCooldowns.Length - 1)];
        consecutiveGiveUps++;
        retryCount = 0;
        networkNotReadyRetries = 0;
        NextAttemptAt = DateTime.Now.Add(cooldown);
        Logger.Shared.Log($"Login failed ({reason}). Giving up; next try in {(int)cooldown.TotalMinutes}m{cooldown.Seconds}s.");
        ShowResult(LoginResult.Failure);

        var generation = retryScheduleGeneration;
        _ = Task.Delay(cooldown + TimeSpan.FromSeconds(1)).ContinueWith(_ =>
        {
            RunOnDispatcher(() =>
            {
                if (retryScheduleGeneration != generation || IsConnecting || !NetworkMonitor.Shared.IsReadyForAutomaticLogin)
                {
                    return;
                }

                NextAttemptAt = null;
                AttemptLogin();
            });
        });

        return Task.CompletedTask;
    }

    private void ScheduleRetry(TimeSpan delay)
    {
        NextAttemptAt = DateTime.Now.Add(delay);
        var generation = retryScheduleGeneration;
        _ = Task.Delay(delay).ContinueWith(_ =>
        {
            RunOnDispatcher(() =>
            {
                if (retryScheduleGeneration != generation)
                {
                    return;
                }

                NextAttemptAt = null;
                AttemptLogin();
            });
        });
    }

    private void Succeed(int token)
    {
        if (!IsLive(token))
        {
            return;
        }

        Finish(token);
        retryScheduleGeneration++;
        retryCount = 0;
        networkNotReadyRetries = 0;
        consecutiveGiveUps = 0;
        NextAttemptAt = null;
        TotalSuccesses++;
        LastConnectedTime = DateTime.Now;
        LastFailureReason = null;
        Logger.Shared.Log("Connected.");
        NotificationService.Shared.ShowConnectedToast();
        ShowResult(LoginResult.Success);
    }

    private void Finish(int token)
    {
        if (!IsLive(token))
        {
            return;
        }

        currentAttempt++;
        attemptPhase = AttemptPhase.Idle;
        IsConnecting = false;
        scriptMessageCompletion = null;
        currentAttemptCts?.Cancel();
        currentAttemptCts?.Dispose();
        currentAttemptCts = null;
        webView?.CoreWebView2?.Stop();
    }

    private void CancelCurrentAttempt(string logMessage)
    {
        if (!IsConnecting)
        {
            return;
        }

        Finish(currentAttempt);
        Logger.Shared.Debug(logMessage);
    }

    private void ReportBlocked(string reason)
    {
        LastFailureReason = reason;
        ShowResult(LoginResult.Failure);
        NextAttemptAt = DateTime.Now.AddMinutes(5);
    }

    private void ShowResult(LoginResult result)
    {
        LastResult = result;
    }

    private Credentials? ReadCredentials()
    {
        var usernameData = CredentialStore.Shared.Read(CredentialStore.UsernameTarget);
        var passwordData = CredentialStore.Shared.Read(CredentialStore.PasswordTarget);
        if (usernameData is null || passwordData is null)
        {
            return null;
        }

        var username = Encoding.UTF8.GetString(usernameData);
        var password = Encoding.UTF8.GetString(passwordData);
        return string.IsNullOrWhiteSpace(username) || string.IsNullOrEmpty(password)
            ? null
            : new Credentials(username, password);
    }

    private static bool IsTrustedPortalUrl(Uri? uri)
    {
        if (uri is null)
        {
            return false;
        }

        return uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)
            && TrustedPortalHosts.Contains(uri.Host)
            && (uri.Port is -1 or 443);
    }

    private bool IsLive(int token)
    {
        return token == currentAttempt && IsConnecting;
    }

    private void EnsureLive(int token)
    {
        if (!IsLive(token))
        {
            throw new OperationCanceledException();
        }
    }

    private void SetField<T>(ref T field, T value, string propertyName)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return;
        }

        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    private static void RunOnDispatcher(Action action)
    {
        var dispatcher = Application.Current.Dispatcher;
        if (dispatcher.CheckAccess())
        {
            action();
        }
        else
        {
            dispatcher.BeginInvoke(action);
        }
    }

    private static string BuildInjectionScript(int token, Credentials credentials)
    {
        return $$"""
        (function() {
          function report(stage, detail) {
            try { window.chrome.webview.postMessage({ attempt: {{token}}, stage: stage, detail: String(detail || '') }); } catch (e) {}
          }
          function setValue(el, val) {
            try {
              var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
              if (d && d.set) { d.set.call(el, val); } else { el.value = val; }
            } catch (e) { el.value = val; }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          function looksLoggedIn() {
            var t = (document.body ? document.body.innerText : '').toLowerCase();
            return t.indexOf('logout') >= 0 || t.indexOf('sign out') >= 0 || t.indexOf('you are signed in') >= 0;
          }
          function isVisible(el) {
            if (!el) return false;
            try {
              var style = window.getComputedStyle(el);
              return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
            } catch (e) { return true; }
          }
          function isClickable(el) {
            var tag = (el.tagName || '').toLowerCase();
            if (!isVisible(el) || el.disabled) return false;
            if (tag === 'button' || tag === 'a') return true;
            if (tag !== 'input') return false;
            var t = (el.type || '').toLowerCase();
            return t === 'submit' || t === 'button' || t === 'image' || t === 'reset';
          }
          function findSubmit(scope) {
            var selectors = [
              '#UserCheck_Login_Button',
              '[onclick*="submitActiveForm"]',
              'input[type="submit"]', 'button[type="submit"]',
              'input[id*="login" i]', 'button[id*="login" i]',
              'a[id*="login" i]', 'a[name*="login" i]',
              'input[name*="login" i]', 'input[value*="login" i]',
              'input[id*="submit" i]', 'button[id*="submit" i]',
              'a[id*="submit" i]', 'input[type="button"]', 'button'
            ];
            var roots = [scope];
            if (scope !== document) roots.push(document);
            for (var r = 0; r < roots.length; r++) {
              for (var s = 0; s < selectors.length; s++) {
                var found;
                try { found = roots[r].querySelectorAll(selectors[s]); } catch (e) { continue; }
                for (var j = 0; j < found.length; j++) {
                  if (isClickable(found[j])) return found[j];
                }
              }
            }
            return null;
          }

          var attempts = 0;
          var timer = setInterval(function() {
            attempts++;
            var pass = document.querySelector('input[type="password"]');
            if (!pass) {
              if (looksLoggedIn()) { clearInterval(timer); report('already', document.title); return; }
              if (attempts > 48) { clearInterval(timer); report('nofields', 'no password field after 24s'); }
              return;
            }
            var scope = pass.form || document;
            var user = null;
            var inputs = scope.querySelectorAll('input');
            for (var i = 0; i < inputs.length; i++) {
              var t = (inputs[i].type || 'text').toLowerCase();
              if (t === 'text' || t === 'email' || t === 'tel') { user = inputs[i]; break; }
            }
            if (!user) {
              if (attempts > 48) { clearInterval(timer); report('nofields', 'no username field after 24s'); }
              return;
            }

            clearInterval(timer);
            setValue(user, {{JsonSerializer.Serialize(credentials.Username)}});
            setValue(pass, {{JsonSerializer.Serialize(credentials.Password)}});

            try {
              if (window.oAuthentication && typeof window.oAuthentication.submitActiveForm === 'function') {
                window.oAuthentication.submitActiveForm();
                report('submitted', 'oAuthentication.submitActiveForm');
                return;
              }
            } catch (e) {}

            var btn = findSubmit(scope);
            if (btn) { btn.click(); report('submitted', (btn.tagName || '') + '#' + (btn.id || '') + '.' + (btn.type || '')); }
            else if (pass.form) {
              if (typeof pass.form.requestSubmit === 'function') pass.form.requestSubmit();
              else pass.form.submit();
              report('submitted', 'native form request');
            }
            else { report('nosubmit', 'no submit control found'); }
          }, 500);
        })();
        """;
    }

    private sealed record Credentials(string Username, string Password);
    private sealed record NavigationResult(bool Success, string Detail, bool NetworkNotReady);
    private sealed record ScriptMessage(string Stage, string Detail);
}
