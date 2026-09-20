using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using SRMAutoconnect.Helpers;

namespace SRMAutoconnect.Views;

public partial class MainPopup : Window
{
    private readonly DashboardView dashboardView = new();
    private readonly LogsView logsView = new();
    private readonly SettingsView settingsView = new();

    public MainPopup()
    {
        InitializeComponent();
        SelectTab(dashboardView, DashboardTab);
    }

    private void DashboardTab_Click(object sender, RoutedEventArgs e)
    {
        SelectTab(dashboardView, DashboardTab);
    }

    private void LogsTab_Click(object sender, RoutedEventArgs e)
    {
        SelectTab(logsView, LogsTab);
    }

    private void SettingsTab_Click(object sender, RoutedEventArgs e)
    {
        SelectTab(settingsView, SettingsTab);
    }

    private void SelectTab(UserControl view, Button selectedButton)
    {
        SelectedContent.Content = view;

        foreach (var button in new[] { DashboardTab, LogsTab, SettingsTab })
        {
            button.Foreground = button == selectedButton ? Theme.GreenBrush : Theme.DimGreenBrush;
            button.FontWeight = button == selectedButton ? FontWeights.Bold : FontWeights.Normal;
            button.Background = button == selectedButton
                ? new SolidColorBrush(Color.FromArgb(0x1F, Theme.GreenColor.R, Theme.GreenColor.G, Theme.GreenColor.B))
                : Brushes.Transparent;
        }
    }
}
