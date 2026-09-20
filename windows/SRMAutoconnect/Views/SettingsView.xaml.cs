using System.Windows;
using System.Windows.Controls;
using SRMAutoconnect.Helpers;

namespace SRMAutoconnect.Views;

public partial class SettingsView : UserControl
{
    public SettingsView()
    {
        InitializeComponent();
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        ShowNotice("SETTINGS UI READY. CREDENTIAL STORAGE ARRIVES IN PHASE 3.", Theme.GreenBrush);
    }

    private void Forget_Click(object sender, RoutedEventArgs e)
    {
        UsernameBox.Clear();
        PasswordBox.Clear();
        ShowNotice("PLACEHOLDER CREDENTIAL FIELDS CLEARED.", Theme.AmberBrush);
    }

    private void Quit_Click(object sender, RoutedEventArgs e)
    {
        Application.Current.Shutdown();
    }

    private void ShowNotice(string message, System.Windows.Media.Brush brush)
    {
        SaveNotice.Text = message;
        SaveNotice.Foreground = brush;
        SaveNotice.Visibility = Visibility.Visible;
    }
}
