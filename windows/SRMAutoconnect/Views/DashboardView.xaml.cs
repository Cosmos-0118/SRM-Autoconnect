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
        UpdateNetworkState();
    }

    private void ForceConnectButton_Click(object sender, RoutedEventArgs e)
    {
        MessageBox.Show(
            "Force Connect will be wired to AutoConnectManager in Phase 6.",
            "SRM Autoconnect",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
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
}
