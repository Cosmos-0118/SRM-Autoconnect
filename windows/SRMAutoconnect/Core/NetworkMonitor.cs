using System.ComponentModel;
using System.Net.NetworkInformation;
using System.Windows;
using System.Windows.Threading;
using ManagedNativeWifi;
using Microsoft.Win32;

namespace SRMAutoconnect.Core;

public sealed class NetworkMonitor : INotifyPropertyChanged, IDisposable
{
    public static NetworkMonitor Shared { get; } = new();

    private const string SrmSsidToken = "SRMIST";
    private const int EmptyReadsToConfirm = 3;

    private readonly DispatcherTimer ssidTimer;
    private int pendingEmptyReads;
    private int networkGeneration;
    private bool latestSsidReadWasUsable;
    private bool reachabilityProbeInFlight;
    private bool lastProbeWasOnline;
    private DateTime? lastReachabilityCheck;
    private int consecutiveOfflineProbes;
    private CancellationTokenSource? offlineConfirmationCts;
    private DateTime? lastWakeHandledAt;
    private bool disposed;

    private string currentSSID = string.Empty;
    private bool isConnectedToSRM;
    private bool isNetworkAvailable;

    public event PropertyChangedEventHandler? PropertyChanged;

    public string CurrentSSID
    {
        get => currentSSID;
        private set
        {
            if (currentSSID == value)
            {
                return;
            }

            currentSSID = value;
            OnPropertyChanged(nameof(CurrentSSID));
        }
    }

    public bool IsConnectedToSRM
    {
        get => isConnectedToSRM;
        private set
        {
            if (isConnectedToSRM == value)
            {
                return;
            }

            isConnectedToSRM = value;
            OnPropertyChanged(nameof(IsConnectedToSRM));
            OnPropertyChanged(nameof(IsReadyForAutomaticLogin));
        }
    }

    public bool IsNetworkAvailable
    {
        get => isNetworkAvailable;
        private set
        {
            if (isNetworkAvailable == value)
            {
                return;
            }

            isNetworkAvailable = value;
            OnPropertyChanged(nameof(IsNetworkAvailable));
            OnPropertyChanged(nameof(IsReadyForAutomaticLogin));
        }
    }

    public bool IsReadyForAutomaticLogin => IsConnectedToSRM && latestSsidReadWasUsable && IsNetworkAvailable;

    private TimeSpan ReachabilityMinInterval => lastProbeWasOnline ? TimeSpan.FromSeconds(60) : TimeSpan.FromSeconds(10);

    private NetworkMonitor()
    {
        NativeWifi.ThrowsOnAnyFailure = false;
        IsNetworkAvailable = NetworkInterface.GetIsNetworkAvailable();

        ssidTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        ssidTimer.Tick += (_, _) => UpdateNetworkStatus();
        ssidTimer.Start();

        NetworkChange.NetworkAvailabilityChanged += HandleNetworkAvailabilityChanged;
        NetworkChange.NetworkAddressChanged += HandleNetworkAddressChanged;
        SystemEvents.PowerModeChanged += HandlePowerModeChanged;

        UpdateNetworkStatus();
    }

    public static bool IsSRMNetwork(string ssid)
    {
        return ssid.Contains(SrmSsidToken, StringComparison.OrdinalIgnoreCase);
    }

    public void CheckInternetIfNeeded()
    {
        EnsureOnDispatcher();

        if (!IsReadyForAutomaticLogin || reachabilityProbeInFlight)
        {
            return;
        }

        if (lastReachabilityCheck is { } last && DateTime.Now - last < ReachabilityMinInterval)
        {
            return;
        }

        lastReachabilityCheck = DateTime.Now;
        reachabilityProbeInFlight = true;
        var generation = networkGeneration;

        ReachabilityProbe.Shared.ProbeReachabilityAsync().ContinueWith(task =>
        {
            var reachability = task.Status == TaskStatus.RanToCompletion
                ? task.Result
                : new Reachability(Online: false, CaptivePortal: false, Detail: $"probe failed ({task.Exception?.GetBaseException().Message ?? "unknown error"})");

            Application.Current.Dispatcher.BeginInvoke(() =>
            {
                reachabilityProbeInFlight = false;
                if (generation != networkGeneration || !IsReadyForAutomaticLogin)
                {
                    Logger.Shared.Debug("Ignoring reachability result from a previous Wi-Fi state.");
                    return;
                }

                HandleReachabilityResult(reachability, generation);
            });
        });
    }

    public void UpdateNetworkStatus()
    {
        EnsureOnDispatcher();

        IsNetworkAvailable = NetworkInterface.GetIsNetworkAvailable();
        var raw = ReadCurrentSSID();
        var observationWasUsable = latestSsidReadWasUsable;
        latestSsidReadWasUsable = !string.IsNullOrWhiteSpace(raw);

        if (observationWasUsable != latestSsidReadWasUsable)
        {
            networkGeneration++;
            ResetOfflineConfirmation();
            if (!latestSsidReadWasUsable)
            {
                HandleReadinessLoss();
            }

            OnPropertyChanged(nameof(IsReadyForAutomaticLogin));
        }

        if (string.IsNullOrWhiteSpace(raw))
        {
            if (string.IsNullOrWhiteSpace(CurrentSSID))
            {
                return;
            }

            pendingEmptyReads++;
            if (pendingEmptyReads < EmptyReadsToConfirm)
            {
                Logger.Shared.Debug($"Transient empty SSID read ({pendingEmptyReads}/{EmptyReadsToConfirm}) - holding '{CurrentSSID}'.");
                return;
            }
        }

        pendingEmptyReads = 0;
        if (raw == CurrentSSID)
        {
            if (!observationWasUsable && latestSsidReadWasUsable)
            {
                Logger.Shared.Debug($"Wi-Fi observation recovered on '{raw}' - rechecking connectivity.");
                lastReachabilityCheck = null;
                CheckInternetIfNeeded();
            }

            return;
        }

        var previous = CurrentSSID;
        var previousWasSrm = IsSRMNetwork(previous);
        CurrentSSID = raw;
        networkGeneration++;
        consecutiveOfflineProbes = 0;
        ResetOfflineConfirmation();
        IsConnectedToSRM = IsSRMNetwork(raw);

        Logger.Shared.Log($"Wi-Fi: {(string.IsNullOrWhiteSpace(previous) ? "none" : previous)} -> {(string.IsNullOrWhiteSpace(raw) ? "none" : raw)}");

        if (IsConnectedToSRM)
        {
            lastReachabilityCheck = null;
            lastProbeWasOnline = false;
            Logger.Shared.Debug("Joined an SRMIST network - checking connectivity.");
            CheckInternetIfNeeded();
        }
        else if (previousWasSrm)
        {
            HandleLeftSrmNetwork();
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        ssidTimer.Stop();
        NetworkChange.NetworkAvailabilityChanged -= HandleNetworkAvailabilityChanged;
        NetworkChange.NetworkAddressChanged -= HandleNetworkAddressChanged;
        SystemEvents.PowerModeChanged -= HandlePowerModeChanged;
        ResetOfflineConfirmation();
    }

    private static string ReadCurrentSSID()
    {
        try
        {
            return NativeWifi.EnumerateConnectedNetworkSsids()
                .Select(ssid => ssid.ToString())
                .FirstOrDefault(ssid => !string.IsNullOrWhiteSpace(ssid))
                ?? string.Empty;
        }
        catch (Exception ex)
        {
            Logger.Shared.Debug($"Could not read Wi-Fi SSID: {ex.Message}");
            return string.Empty;
        }
    }

    private void HandleReachabilityResult(Reachability reachability, int generation)
    {
        lastProbeWasOnline = reachability.Online;

        if (reachability.Online)
        {
            consecutiveOfflineProbes = 0;
            ResetOfflineConfirmation();
            Logger.Shared.Debug($"Internet reachable on SRMIST ({reachability.Detail}).");
            return;
        }

        consecutiveOfflineProbes++;
        if (consecutiveOfflineProbes == 1)
        {
            Logger.Shared.Log($"No internet on SRMIST ({reachability.Detail}). Confirming before portal login.");
            ScheduleOfflineConfirmation(generation);
            return;
        }

        Logger.Shared.Log(reachability.CaptivePortal
            ? $"Captive portal detected ({reachability.Detail}). Logging in..."
            : $"No internet confirmed ({reachability.Detail}). Starting portal login...");
        AutoConnectManager.Shared.AttemptLoginAfterConfirmedOutage(reachability);
    }

    private void ScheduleOfflineConfirmation(int generation)
    {
        ResetOfflineConfirmation();
        offlineConfirmationCts = new CancellationTokenSource();
        var token = offlineConfirmationCts.Token;

        Task.Delay(TimeSpan.FromSeconds(3), token).ContinueWith(task =>
        {
            if (task.IsCanceled)
            {
                return;
            }

            Application.Current.Dispatcher.BeginInvoke(() =>
            {
                if (generation != networkGeneration || !IsReadyForAutomaticLogin)
                {
                    return;
                }

                offlineConfirmationCts = null;
                lastReachabilityCheck = null;
                CheckInternetIfNeeded();
            });
        }, CancellationToken.None);
    }

    private void HandleNetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            IsNetworkAvailable = e.IsAvailable;
            HandleNetworkPathChanged(e.IsAvailable ? "available" : "unavailable");
        });
    }

    private void HandleNetworkAddressChanged(object? sender, EventArgs e)
    {
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            IsNetworkAvailable = NetworkInterface.GetIsNetworkAvailable();
            HandleNetworkPathChanged("address changed");
        });
    }

    private void HandleNetworkPathChanged(string reason)
    {
        networkGeneration++;
        consecutiveOfflineProbes = 0;
        ResetOfflineConfirmation();
        lastReachabilityCheck = null;

        if (!IsNetworkAvailable)
        {
            HandleReadinessLoss();
            Logger.Shared.Debug($"Network path is {reason} - not probing.");
            return;
        }

        UpdateNetworkStatus();
        CheckInternetIfNeeded();
    }

    private void HandlePowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode != PowerModes.Resume)
        {
            return;
        }

        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            if (lastWakeHandledAt is { } last && DateTime.Now - last < TimeSpan.FromSeconds(3))
            {
                Logger.Shared.Debug("Duplicate wake notification - already settling.");
                return;
            }

            lastWakeHandledAt = DateTime.Now;
            Logger.Shared.Debug("System resumed. Rechecking network in 5s...");
            AutoConnectManager.Shared.CancelPendingRetryForWake();
            HandleReadinessLoss();

            Task.Delay(TimeSpan.FromSeconds(5)).ContinueWith(_ =>
            {
                Application.Current.Dispatcher.BeginInvoke(() =>
                {
                    lastReachabilityCheck = null;
                    UpdateNetworkStatus();
                    CheckInternetIfNeeded();
                });
            });
        });
    }

    private void HandleReadinessLoss()
    {
        ResetOfflineConfirmation();
        AutoConnectManager.Shared.CancelAutomaticLoginForReadinessLoss();
        Logger.Shared.Debug("Network readiness was lost - automatic portal login is paused until readiness returns.");
    }

    private void HandleLeftSrmNetwork()
    {
        ResetOfflineConfirmation();
        lastReachabilityCheck = null;
        consecutiveOfflineProbes = 0;
        AutoConnectManager.Shared.CancelAutomaticLoginForNetworkChange();
        Logger.Shared.Debug("Left SRMIST - discarded pending portal retry state.");
    }

    private void ResetOfflineConfirmation()
    {
        offlineConfirmationCts?.Cancel();
        offlineConfirmationCts?.Dispose();
        offlineConfirmationCts = null;
    }

    private static void EnsureOnDispatcher()
    {
        if (!Application.Current.Dispatcher.CheckAccess())
        {
            throw new InvalidOperationException("NetworkMonitor state must be updated on the WPF dispatcher.");
        }
    }

    private void OnPropertyChanged(string propertyName)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
