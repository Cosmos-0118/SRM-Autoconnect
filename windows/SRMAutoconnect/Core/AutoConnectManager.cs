using System.ComponentModel;
using System.IO;
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
    private const int SubmitOutcomeTimeoutSeconds = 10;
    private const int AttemptHardTimeoutSeconds = 120;

    private static readonly string WebViewUserDataFolder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SRMAutoconnect",
        "WebView2");

    private static readonly string SettingsFilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SRMAutoconnect",
        "settings.json");

    private Window? hostWindow;
    private WebView2? webView;
    private Task? webViewInitTask;
    private bool webViewHandlersAttached;
    private TaskCompletionSource<NavigationResult>? portalNavigationCompletion;
    private TaskCompletionSource<ScriptMessage>? scriptMessageCompletion;
    private string? injectionScriptId;
    private CancellationTokenSource? currentAttemptCts;
    private int currentAttempt;
    private int retryScheduleGeneration;
    private int retryCount;
    private int networkNotReadyRetries;
    private int consecutiveGiveUps;
    private bool sawNetworkNotReadyInAttempt;
    private bool currentAttemptWasForced;
    private int loginSubmittedForAttempt = -1;
    private Credentials? currentCredentials;
    private AttemptPhase attemptPhase = AttemptPhase.Idle;

    private int totalSuccesses;
    private int totalFailures;
    private DateTime? lastConnectedTime;
    private bool isConnecting;
    private DateTime? nextAttemptAt;
    private LoginResult? lastResult;
    private string? lastFailureReason;
    private bool showPortalWindow;

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

    public bool ShowPortalWindow
    {
        get => showPortalWindow;
        private set => SetField(ref showPortalWindow, value, nameof(ShowPortalWindow));
    }

    private AutoConnectManager()
    {
        ShowPortalWindow = ReadShowPortalWindow();
        Logger.Shared.DebugEnabled = ShowPortalWindow;
    }

    public void SetShowPortalWindow(bool enabled)
    {
        ShowPortalWindow = enabled;
        Logger.Shared.DebugEnabled = enabled;
        WriteShowPortalWindow(enabled);
        ApplyPortalWindowDebugState();
        Logger.Shared.Log(enabled
            ? "Portal debug window enabled."
            : "Portal debug window hidden.");
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

    public void PrewarmWebView()
    {
        RunOnDispatcher(() => _ = PrewarmWebViewAsync());
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
        loginSubmittedForAttempt = -1;
        currentCredentials = credentials;
        attemptPhase = AttemptPhase.Preflight;
        IsConnecting = true;
        NextAttemptAt = null;
        LastResult = null;
        LastFailureReason = null;

        currentAttemptCts?.Dispose();
        currentAttemptCts = new CancellationTokenSource(TimeSpan.FromSeconds(AttemptHardTimeoutSeconds));
        var cancellationToken = currentAttemptCts.Token;
        cancellationToken.Register(() =>
        {
            RunOnDispatcher(() =>
            {
                if (IsLive(token))
                {
                    _ = FailAsync(token, $"attempt timed out after {AttemptHardTimeoutSeconds}s");
                }
            });
        });

        try
        {
            var reachability = knownReachability ?? await ReachabilityProbe.Shared.ProbeReachabilityAsync(cancellationToken);
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

            await LoadPortalAndSubmitAsync(token, cancellationToken);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            HandleMissingWebViewRuntime(token);
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

    private async Task LoadPortalAndSubmitAsync(int token, CancellationToken cancellationToken)
    {
        attemptPhase = AttemptPhase.LoadingPortal;
        await EnsureWebViewAsync(cancellationToken);
        EnsureLive(token);

        portalNavigationCompletion = new TaskCompletionSource<NavigationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        scriptMessageCompletion = new TaskCompletionSource<ScriptMessage>(TaskCreationOptions.RunContinuationsAsynchronously);

        var navigation = await NavigateToPortalAsync(token, cancellationToken);
        EnsureLive(token);

        if (!navigation.Success)
        {
            if (navigation.NetworkNotReady)
            {
                sawNetworkNotReadyInAttempt = true;
            }

            throw new InvalidOperationException($"portal unreachable - {navigation.Detail}");
        }

        attemptPhase = AttemptPhase.WaitingForLoginForm;
        var scriptMessage = await WaitForScriptMessageAsync(cancellationToken);
        EnsureLive(token);
        await HandleScriptStageAsync(token, scriptMessage, cancellationToken);
    }

    private async Task HandleScriptStageAsync(int token, ScriptMessage scriptMessage, CancellationToken cancellationToken)
    {
        switch (scriptMessage.Stage)
        {
            case "submitted":
                attemptPhase = AttemptPhase.Verifying;
                Logger.Shared.Debug($"Credentials submitted via '{scriptMessage.Detail}'. Waiting for portal response...");
                var outcome = await WaitForSubmitOutcomeAsync(cancellationToken);
                EnsureLive(token);
                await HandleSubmitOutcomeAsync(token, outcome, cancellationToken);
                break;
            case "already":
                attemptPhase = AttemptPhase.Verifying;
                Logger.Shared.Debug("Portal reports an existing session. Verifying...");
                await VerifyAsync(token, remaining: 3, cancellationToken);
                break;
            case "accepted":
                attemptPhase = AttemptPhase.Verifying;
                Logger.Shared.Debug($"Portal accepted login ({scriptMessage.Detail}). Verifying...");
                await VerifyAsync(token, remaining: 8, cancellationToken);
                break;
            case "rejected":
                throw new InvalidOperationException($"portal rejected: {scriptMessage.Detail}");
            case "noresponse":
                throw new InvalidOperationException($"submit produced no response ({scriptMessage.Detail})");
            case "nofields":
                throw new InvalidOperationException($"login form never appeared ({scriptMessage.Detail})");
            case "nosubmit":
                throw new InvalidOperationException("no submit button on the login form");
            default:
                throw new InvalidOperationException($"login script reported unexpected stage '{scriptMessage.Stage}'");
        }
    }

    private async Task HandleSubmitOutcomeAsync(int token, ScriptMessage outcome, CancellationToken cancellationToken)
    {
        switch (outcome.Stage)
        {
            case "accepted":
            case "already":
                Logger.Shared.Debug($"Portal accepted login ({outcome.Detail}). Verifying...");
                await VerifyAsync(token, remaining: 8, cancellationToken);
                break;
            case "rejected":
                throw new InvalidOperationException($"portal rejected: {outcome.Detail}");
            case "noresponse":
                throw new InvalidOperationException($"submit produced no response ({outcome.Detail})");
            default:
                throw new InvalidOperationException($"submit produced no response ({outcome.Stage}: {outcome.Detail})");
        }
    }

    private async Task PrewarmWebViewAsync()
    {
        try
        {
            await EnsureWebViewAsync();
            Logger.Shared.Debug("WebView2 ready.");
        }
        catch (WebView2RuntimeNotFoundException)
        {
            Logger.Shared.Log("WebView2 runtime is not installed. Portal login cannot run until it is.");
        }
        catch (Exception ex)
        {
            Logger.Shared.Debug($"WebView2 prewarm failed: {ex.Message}");
        }
    }

    private Task EnsureWebViewAsync(CancellationToken cancellationToken = default)
    {
        if (webView?.CoreWebView2 is not null)
        {
            return Task.CompletedTask;
        }

        webViewInitTask ??= InitializeWebViewAsync();
        return webViewInitTask.WaitAsync(cancellationToken);
    }

    private async Task InitializeWebViewAsync()
    {
        try
        {
            hostWindow ??= new Window
            {
                Width = 1024,
                Height = 768,
                Left = -20000,
                Top = -20000,
                ShowInTaskbar = false,
                ShowActivated = false,
                WindowStyle = WindowStyle.ToolWindow,
                ResizeMode = ResizeMode.NoResize,
                Title = "SRM Autoconnect - portal"
            };

            webView ??= new WebView2 { Width = 1024, Height = 768 };
            hostWindow.Content = webView;
            ApplyPortalWindowDebugState();
            if (!hostWindow.IsVisible)
            {
                hostWindow.Show();
            }

            Directory.CreateDirectory(WebViewUserDataFolder);
            var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: WebViewUserDataFolder);
            await webView.EnsureCoreWebView2Async(environment);
            ApplyPortalWindowDebugState();

            if (!webViewHandlersAttached)
            {
                webView.CoreWebView2.NavigationCompleted += HandleNavigationCompleted;
                webView.CoreWebView2.WebMessageReceived += HandleWebMessageReceived;
                webViewHandlersAttached = true;
            }
        }
        catch
        {
            webViewInitTask = null;
            throw;
        }
    }

    private async Task<NavigationResult> NavigateToPortalAsync(int token, CancellationToken cancellationToken)
    {
        if (webView?.CoreWebView2 is null)
        {
            throw new InvalidOperationException("WebView2 is not ready.");
        }

        Logger.Shared.Debug($"Loading portal: {PortalUrl}");
        await ResetPortalBrowserAsync(cancellationToken);
        await RegisterInjectionScriptAsync(token, currentCredentials!, cancellationToken);
        EnsureLive(token);
        webView.CoreWebView2.Navigate(PortalUrl.ToString());

        var finished = await Task.WhenAny(
            portalNavigationCompletion!.Task,
            Task.Delay(TimeSpan.FromSeconds(PortalNavigationTimeoutSeconds), cancellationToken));

        if (finished != portalNavigationCompletion.Task)
        {
            cancellationToken.ThrowIfCancellationRequested();
            webView.CoreWebView2.Stop();
            return new NavigationResult(false, $"navigation timed out after {PortalNavigationTimeoutSeconds}s", NetworkNotReady: false);
        }

        return await portalNavigationCompletion.Task;
    }

    private async Task<ScriptMessage> WaitForScriptMessageAsync(CancellationToken cancellationToken)
    {
        if (scriptMessageCompletion is null)
        {
            throw new InvalidOperationException("Login script is not waiting for a result.");
        }

        var finished = await Task.WhenAny(
            scriptMessageCompletion.Task,
            Task.Delay(TimeSpan.FromSeconds(LoginFormTimeoutSeconds), cancellationToken));

        if (finished != scriptMessageCompletion.Task)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw new InvalidOperationException($"login form did not become ready after {LoginFormTimeoutSeconds}s");
        }

        return await scriptMessageCompletion.Task;
    }

    private async Task<ScriptMessage> WaitForSubmitOutcomeAsync(CancellationToken cancellationToken)
    {
        scriptMessageCompletion ??= new TaskCompletionSource<ScriptMessage>(TaskCreationOptions.RunContinuationsAsynchronously);

        var finished = await Task.WhenAny(
            scriptMessageCompletion.Task,
            Task.Delay(TimeSpan.FromSeconds(SubmitOutcomeTimeoutSeconds), cancellationToken));

        if (finished != scriptMessageCompletion.Task)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return new ScriptMessage("noresponse", $"portal did not respond after {SubmitOutcomeTimeoutSeconds}s");
        }

        return await scriptMessageCompletion.Task;
    }

    private async Task InjectLoginScriptAsync(int token, Credentials credentials, CancellationToken cancellationToken)
    {
        if (webView?.CoreWebView2 is null)
        {
            return;
        }

        try
        {
            await webView.CoreWebView2.ExecuteScriptAsync(BuildInjectionScript(token, credentials))
                .WaitAsync(cancellationToken);
            if (IsLive(token))
            {
                Logger.Shared.Debug($"Login script injected into {Redact(webView.Source)}; waiting for form.");
            }
        }
        catch (OperationCanceledException)
        {
            // Attempt watchdog or Finish() cancelled this injection.
        }
        catch (Exception ex)
        {
            scriptMessageCompletion?.TrySetException(
                new InvalidOperationException($"script injection failed: {ex.Message}"));
        }
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

    private void HandleNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!IsConnecting)
        {
            return;
        }

        if (loginSubmittedForAttempt == currentAttempt)
        {
            Logger.Shared.Debug("Post-submit navigation; awaiting reachability verification.");
            scriptMessageCompletion?.TrySetResult(new ScriptMessage("accepted", "post-submit navigation"));
            return;
        }

        if (!e.IsSuccess)
        {
            if (e.WebErrorStatus is CoreWebView2WebErrorStatus.OperationCanceled)
            {
                return;
            }

            var notReady = e.WebErrorStatus is CoreWebView2WebErrorStatus.Disconnected;
            if (notReady)
            {
                sawNetworkNotReadyInAttempt = true;
            }

            var detail = e.WebErrorStatus.ToString();
            if (portalNavigationCompletion is { Task.IsCompleted: false })
            {
                portalNavigationCompletion.TrySetResult(new NavigationResult(false, detail, notReady));
                return;
            }

            scriptMessageCompletion?.TrySetException(
                new InvalidOperationException($"portal navigation failed: {detail}"));
            return;
        }

        var uri = webView?.Source;
        Logger.Shared.Debug($"Loaded: {Redact(uri)}");

        if (!IsTrustedPortalUrl(uri))
        {
            const string reason = "redirected outside the trusted HTTPS SRM portal";
            if (portalNavigationCompletion is { Task.IsCompleted: false })
            {
                portalNavigationCompletion.TrySetResult(new NavigationResult(false, reason, NetworkNotReady: false));
                return;
            }

            scriptMessageCompletion?.TrySetException(new InvalidOperationException(reason));
            return;
        }

        portalNavigationCompletion?.TrySetResult(new NavigationResult(true, "loaded", NetworkNotReady: false));

        if (currentCredentials is null)
        {
            return;
        }

        attemptPhase = AttemptPhase.WaitingForLoginForm;
        _ = InjectLoginScriptAsync(currentAttempt, currentCredentials, currentAttemptCts?.Token ?? CancellationToken.None);
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

            if (stage is "discover")
            {
                Logger.Shared.Debug($"Portal form: {detail}");
                return;
            }

            if (stage is "submitted" or "already")
            {
                loginSubmittedForAttempt = attempt;
                RemoveInjectionScript();
            }

            var current = scriptMessageCompletion;
            if (stage is "submitted")
            {
                // Arm the outcome wait before completing "submitted", so a fast
                // post-submit navigation cannot land on an already-completed TCS.
                scriptMessageCompletion = new TaskCompletionSource<ScriptMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
            }

            current?.TrySetResult(new ScriptMessage(stage, detail));
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
            ScheduleRetry(delay, networkNotReadyRetry: true);
            return Task.CompletedTask;
        }

        if (retryCount < RetryDelays.Length)
        {
            var delay = RetryDelays[retryCount] + TimeSpan.FromMilliseconds(Random.Shared.Next(0, 1500));
            retryCount++;
            Logger.Shared.Log($"Login failed ({reason}). Retry {retryCount}/{RetryDelays.Length} in {(int)delay.TotalSeconds}s.");
            ScheduleRetry(delay, networkNotReadyRetry: false);
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

    private void ScheduleRetry(TimeSpan delay, bool networkNotReadyRetry)
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
                if (!NetworkMonitor.Shared.IsReadyForAutomaticLogin)
                {
                    if (networkNotReadyRetry)
                    {
                        networkNotReadyRetries = Math.Max(0, networkNotReadyRetries - 1);
                    }
                    else
                    {
                        retryCount = Math.Max(0, retryCount - 1);
                    }

                    Logger.Shared.Debug("Retry skipped - network is not ready. Rung restored.");
                    return;
                }

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
        currentCredentials = null;
        portalNavigationCompletion = null;
        scriptMessageCompletion = null;
        RemoveInjectionScript();
        currentAttemptCts?.Cancel();
        webView?.CoreWebView2?.Stop();
    }

    private Task ResetPortalBrowserAsync(CancellationToken cancellationToken)
    {
        if (webView?.CoreWebView2 is null)
        {
            return Task.CompletedTask;
        }

        cancellationToken.ThrowIfCancellationRequested();
        webView.CoreWebView2.Stop();
        // macOS never wipes cookies between attempts. Clearing them here discarded
        // the portal's session before RSA/AJAX login could finish.
        Logger.Shared.Debug("Keeping WebView2 cookies so the portal session can continue.");
        return Task.CompletedTask;
    }

    private async Task RegisterInjectionScriptAsync(int token, Credentials credentials, CancellationToken cancellationToken)
    {
        if (webView?.CoreWebView2 is null)
        {
            return;
        }

        RemoveInjectionScript();
        injectionScriptId = await webView.CoreWebView2
            .AddScriptToExecuteOnDocumentCreatedAsync(BuildInjectionScript(token, credentials))
            .WaitAsync(cancellationToken);
        Logger.Shared.Debug("Portal login script registered for every document, including iframes.");
    }

    private void RemoveInjectionScript()
    {
        if (webView?.CoreWebView2 is null || injectionScriptId is null)
        {
            return;
        }

        webView.CoreWebView2.RemoveScriptToExecuteOnDocumentCreated(injectionScriptId);
        injectionScriptId = null;
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

    private void HandleMissingWebViewRuntime(int token)
    {
        if (IsLive(token))
        {
            Finish(token);
        }

        Logger.Shared.Log("WebView2 runtime is not installed. Portal login cannot run until it is.");
        ReportBlocked("WebView2 runtime missing");
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

    private static string Redact(Uri? uri)
    {
        if (uri is null)
        {
            return string.Empty;
        }

        var hadQueryOrFragment = !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment);
        return uri.GetLeftPart(UriPartial.Path) + (hadQueryOrFragment ? " (query redacted)" : string.Empty);
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

    private void ApplyPortalWindowDebugState()
    {
        if (hostWindow is not null)
        {
            if (ShowPortalWindow)
            {
                hostWindow.WindowStyle = WindowStyle.SingleBorderWindow;
                hostWindow.ResizeMode = ResizeMode.CanResize;
                hostWindow.ShowInTaskbar = true;
                hostWindow.Title = "SRM Autoconnect - portal (debug)";
                hostWindow.Left = 80;
                hostWindow.Top = 80;
                hostWindow.Width = 1024;
                hostWindow.Height = 768;
                if (!hostWindow.IsVisible)
                {
                    hostWindow.Show();
                }
            }
            else
            {
                hostWindow.WindowStyle = WindowStyle.ToolWindow;
                hostWindow.ResizeMode = ResizeMode.NoResize;
                hostWindow.ShowInTaskbar = false;
                hostWindow.Title = "SRM Autoconnect - portal";
                hostWindow.Left = -20000;
                hostWindow.Top = -20000;
            }
        }

        if (webView?.CoreWebView2 is not null)
        {
            webView.CoreWebView2.Settings.AreDevToolsEnabled = ShowPortalWindow;
            webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = ShowPortalWindow;
        }
    }

    private static bool ReadShowPortalWindow()
    {
        try
        {
            if (!File.Exists(SettingsFilePath))
            {
                return false;
            }

            using var doc = JsonDocument.Parse(File.ReadAllText(SettingsFilePath));
            return doc.RootElement.TryGetProperty("showPortalWindow", out var property)
                && property.ValueKind is JsonValueKind.True;
        }
        catch
        {
            return false;
        }
    }

    private static void WriteShowPortalWindow(bool enabled)
    {
        try
        {
            var directory = Path.GetDirectoryName(SettingsFilePath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(
                SettingsFilePath,
                JsonSerializer.Serialize(new { showPortalWindow = enabled }));
        }
        catch (Exception ex)
        {
            Logger.Shared.Debug($"Could not save portal debug setting: {ex.Message}");
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
          try {
            var host = String((location && location.hostname) || '').toLowerCase();
            var protocol = String((location && location.protocol) || '').toLowerCase();
            if (protocol !== 'https:' || host !== 'iac.srmist.edu.in') return;
            if (window.__srmInjectedAttempt === {{token}}) return;
            window.__srmInjectedAttempt = {{token}};
          } catch (e) { return; }

          function report(stage, detail) {
            try { window.chrome.webview.postMessage({ attempt: {{token}}, stage: stage, detail: String(detail || '') }); } catch (e) {}
          }
          function setValue(el, val) {
            try { el.focus(); } catch (e) {}
            try {
              var d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
              if (d && d.set) { d.set.call(el, val); } else { el.value = val; }
            } catch (e) { el.value = val; }
            try { el.setAttribute('value', val); } catch (e) {}
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new InputEvent('input', { bubbles: true, data: val }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'a' }));
            el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'a' }));
          }
          function portalHandler(win) {
            try {
              if (win && win.oAuthentication && typeof win.oAuthentication.submitActiveForm === 'function') {
                return win.oAuthentication.submitActiveForm.bind(win.oAuthentication);
              }
            } catch (e) {}
            return null;
          }
          function firstVisible(nodes) {
            for (var i = 0; i < nodes.length; i++) {
              if (isVisible(nodes[i])) return nodes[i];
            }
            return null;
          }
          function looksLoggedIn() {
            var t = (document.body ? document.body.innerText : '').toLowerCase();
            return t.indexOf('logout') >= 0 || t.indexOf('sign out') >= 0
              || t.indexOf('you are signed in') >= 0 || t.indexOf('already logged') >= 0
              || t.indexOf('already connected') >= 0 || t.indexOf('you are connected') >= 0
              || t.indexOf('authentication successful') >= 0;
          }
          function rsaReady() {
            try { return !!window.cpRSAobj; } catch (e) { return false; }
          }
          function describeEl(el) {
            if (!el) return 'none';
            return (el.tagName || '') + '#' + (el.id || '') + '.' + (el.type || '') + (isVisible(el) ? ' vis' : ' hid');
          }
          function iframeDepth() {
            var depth = 0, win = window;
            try {
              while (win.parent && win.parent !== win) { depth++; win = win.parent; }
            } catch (e) {}
            return depth;
          }
          function describePage() {
            var iframeCount = 0;
            try { iframeCount = document.querySelectorAll('iframe').length; } catch (e) {}
            return (document.title || '')
              + ' ready=' + document.readyState
              + ' rsa=' + rsaReady()
              + ' iframes=' + iframeCount
              + ' iframeDepth=' + iframeDepth()
              + ' path=' + String(location.pathname || '');
          }
          function findPassword(root) {
            root = root || document;
            var nodes = [];
            try {
              nodes = root.querySelectorAll('input[type="password"], input[name*="pass" i], input[id*="password" i], input[id*="LoginUserPassword_auth_password" i]');
            } catch (e) {}
            return firstVisible(nodes);
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
          function findSubmit(scope, ownerDoc) {
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
            var roots = [];
            if (scope) roots.push(scope);
            if (ownerDoc && ownerDoc !== scope) roots.push(ownerDoc);
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
          function portalErrorText() {
            var el = document.getElementById('LoginSequencePage_Content');
            if (!el) return '';
            var t = (el.innerText || '').replace(/\s+/g, ' ').trim();
            var lower = t.toLowerCase();
            var hints = ['invalid', 'incorrect', 'denied', 'failed', 'wrong password', 'authentication unsuccessful', 'unable to authenticate', 'login error'];
            for (var i = 0; i < hints.length; i++) {
              if (lower.indexOf(hints[i]) >= 0) return t.slice(0, 180);
            }
            return '';
          }
          function watchOutcome(submitDetail) {
            var startHref = String(location.href || '');
            var ticks = 0;
            var watch = setInterval(function() {
              ticks++;
              try {
                if (window.cpRSAobj && window.cpRSAobj.isAuthenticated) {
                  clearInterval(watch);
                  report('accepted', 'cpRSAobj.isAuthenticated');
                  return;
                }
              } catch (e) {}
              if (looksLoggedIn()) {
                clearInterval(watch);
                report('accepted', 'portal session');
                return;
              }
              var href = String(location.href || '');
              if (href && href !== startHref) {
                clearInterval(watch);
                report('accepted', 'navigated');
                return;
              }
              var err = portalErrorText();
              if (err) {
                clearInterval(watch);
                report('rejected', err);
                return;
              }
              if (ticks >= 40) {
                clearInterval(watch);
                report('noresponse', submitDetail || 'no portal response after 10s');
              }
            }, 250);
          }

          var attempts = 0;
          var readyTicks = 0;
          var lastReadyFp = '';
          var timer = setInterval(function() {
            attempts++;
            if (document.readyState !== 'complete') {
              if (attempts > 100) { clearInterval(timer); report('nofields', 'document never reached complete (' + describePage() + ')'); }
              return;
            }
            var pass = findPassword(document);
            if (!pass) {
              if (looksLoggedIn()) { clearInterval(timer); report('already', document.title); return; }
              if (attempts > 100) { clearInterval(timer); report('nofields', 'no visible password field after 25s (' + describePage() + ')'); }
              return;
            }
            var ownerDoc = pass.ownerDocument || document;
            var scope = pass.form || ownerDoc;
            var user = null;
            var inputs = [];
            try { inputs = scope.querySelectorAll('input'); } catch (e) {}
            var userNodes = [];
            for (var i = 0; i < inputs.length; i++) {
              var t = (inputs[i].type || 'text').toLowerCase();
              if (t === 'text' || t === 'email' || t === 'tel') userNodes.push(inputs[i]);
            }
            user = firstVisible(userNodes);
            if (!user) {
              if (attempts > 100) { clearInterval(timer); report('nofields', 'no visible username field after 25s (' + describePage() + ')'); }
              return;
            }

            var win = (ownerDoc && ownerDoc.defaultView) || window;
            var handler = portalHandler(win) || portalHandler(window);
            var btn = findSubmit(scope, ownerDoc);
            if (!rsaReady() || (!handler && !btn)) {
              if (attempts > 100) {
                clearInterval(timer);
                if (!rsaReady()) report('nofields', 'cpRSAobj never became ready (' + describePage() + ')');
                else report('nosubmit', 'no submit control found');
              }
              return;
            }

            var fp = [pass.id || '', user.id || '', handler ? 'h' : '', btn ? (btn.id || btn.tagName) : '', 'rsa'].join('|');
            if (fp !== lastReadyFp) { lastReadyFp = fp; readyTicks = 1; return; }
            readyTicks++;
            if (readyTicks < 2) return;

            clearInterval(timer);
            if (!window.__srmDiscovered) {
              window.__srmDiscovered = true;
              report('discover', 'ready=' + document.readyState
                + ' rsa=' + rsaReady()
                + ' user=' + describeEl(user)
                + ' pass=' + describeEl(pass)
                + ' btn=' + describeEl(btn)
                + ' handler=' + !!handler
                + ' iframeDepth=' + iframeDepth());
            }

            setValue(user, {{JsonSerializer.Serialize(credentials.Username)}});
            setValue(pass, {{JsonSerializer.Serialize(credentials.Password)}});

            setTimeout(function() {
              setValue(user, {{JsonSerializer.Serialize(credentials.Username)}});
              setValue(pass, {{JsonSerializer.Serialize(credentials.Password)}});
              btn = findSubmit(scope, ownerDoc) || btn;
              handler = portalHandler(win) || portalHandler(window) || handler;
              var submitDetail = '';
              if (handler) {
                try { handler(); } catch (e) {}
                submitDetail = 'oAuthentication.submitActiveForm';
                report('submitted', submitDetail);
                watchOutcome(submitDetail);
                return;
              }
              if (btn) {
                try { btn.click(); } catch (e) {}
                submitDetail = (btn.tagName || '') + '#' + (btn.id || '') + '.' + (btn.type || '');
                report('submitted', submitDetail);
                watchOutcome(submitDetail);
                return;
              }
              if (pass.form) {
                if (typeof pass.form.requestSubmit === 'function') pass.form.requestSubmit();
                else pass.form.submit();
                submitDetail = 'native form request';
                report('submitted', submitDetail);
                watchOutcome(submitDetail);
                return;
              }
              report('nosubmit', 'no submit control found');
            }, 400);
          }, 250);
        })();
        """;
    }

    private sealed record Credentials(string Username, string Password);
    private sealed record NavigationResult(bool Success, string Detail, bool NetworkNotReady);
    private sealed record ScriptMessage(string Stage, string Detail);
}
