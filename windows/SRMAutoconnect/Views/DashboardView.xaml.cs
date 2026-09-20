using System.Windows;
using System.Windows.Controls;

namespace SRMAutoconnect.Views;

public partial class DashboardView : UserControl
{
    public DashboardView()
    {
        InitializeComponent();
    }

    private void ForceConnectButton_Click(object sender, RoutedEventArgs e)
    {
        MessageBox.Show(
            "Force Connect will be wired to AutoConnectManager in Phase 6.",
            "SRM Autoconnect",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }
}
