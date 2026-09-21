using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using SRMAutoconnect.Core;
using SRMAutoconnect.Helpers;

namespace SRMAutoconnect.Views;

public partial class DashboardView : UserControl
{
    public DashboardView()
    {
        InitializeComponent();
        NetworkMonitor.Shared.PropertyChanged += NetworkMonitor_PropertyChanged;
        AutoConnectManager.Shared.PropertyChanged += AutoConnectManager_PropertyChanged;
        UpdateNetworkState();
        UpdateAutoConnectState();
    }

    private void ForceConnectButton_Click(object sender, RoutedEventArgs e)
    {
        AutoConnectManager.Shared.AttemptLogin(force: true);
    }

    private void NetworkMonitor_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(NetworkMonitor.CurrentSSID) or nameof(NetworkMonitor.IsConnectedToSRM))
        {
            UpdateNetworkState();
        }
    }

    private void UpdateNetworkState()
    {
        var monitor = NetworkMonitor.Shared;
        CurrentNetworkText.Text = string.IsNullOrWhiteSpace(monitor.CurrentSSID) ? "None" : monitor.CurrentSSID;
        ConnectionDot.Fill = monitor.IsConnectedToSRM ? Theme.GreenBrush : Brushes.Red;
    }

    private void AutoConnectManager_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        UpdateAutoConnectState();
    }

    private void UpdateAutoConnectState()
    {
        var manager = AutoConnectManager.Shared;
        SuccessValueText.Text = manager.TotalSuccesses.ToString();
        FailedValueText.Text = manager.TotalFailures.ToString();
        LastConnectedText.Text = manager.LastConnectedTime?.ToString("HH:mm:ss") ?? "NEVER";

        var hasFutureAttempt = manager.NextAttemptAt is { } next && next > DateTime.Now;
        NextAttemptRow.Visibility = hasFutureAttempt ? Visibility.Visible : Visibility.Collapsed;
        if (hasFutureAttempt && manager.NextAttemptAt is { } nextAttempt)
        {
            var seconds = Math.Max(0, (int)(nextAttempt - DateTime.Now).TotalSeconds);
            NextAttemptText.Text = $"{seconds}s";
        }

        ConnectingPanel.Visibility = manager.IsConnecting ? Visibility.Visible : Visibility.Collapsed;
        ForceConnectButton.IsEnabled = !manager.IsConnecting;
        ForceConnectButton.Content = manager.IsConnecting ? "> CONNECTING... <" : "> FORCE CONNECT <";

        ResultBanner.Visibility = manager.LastResult is null ? Visibility.Collapsed : Visibility.Visible;
        if (manager.LastResult is null)
        {
            return;
        }

        var failed = manager.LastResult == LoginResult.Failure;
        ResultBanner.BorderBrush = failed ? Brushes.Red : Theme.GreenBrush;
        ResultTitleText.Foreground = failed ? Brushes.Red : Theme.GreenBrush;
        ResultDetailText.Foreground = failed ? Brushes.Red : Theme.DimGreenBrush;
        ResultTitleText.Text = manager.LastResult switch
        {
            LoginResult.Success => "CONNECTED",
            LoginResult.AlreadyOnline => "ALREADY ONLINE",
            LoginResult.Failure => "LOGIN FAILED",
            _ => string.Empty
        };
        ResultDetailText.Text = failed && !string.IsNullOrWhiteSpace(manager.LastFailureReason)
            ? manager.LastFailureReason.ToUpperInvariant()
            : string.Empty;
    }
}
