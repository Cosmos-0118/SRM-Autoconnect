using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using SRMAutoconnect.Helpers;

namespace SRMAutoconnect.Views;

public partial class LogsView : UserControl
{
    private readonly DispatcherTimer flashTimer;

    public LogsView()
    {
        InitializeComponent();

        flashTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.6) };
        flashTimer.Tick += (_, _) =>
        {
            flashTimer.Stop();
            ActionNote.Visibility = Visibility.Collapsed;
        };
    }

    private void CopyLogs_Click(object sender, RoutedEventArgs e)
    {
        Clipboard.SetText("[00:00:00] Windows UI shell ready.\n[00:00:01] Logger will be wired in Phase 2.");
        Flash("COPIED 2");
    }

    private void ClearLogs_Click(object sender, RoutedEventArgs e)
    {
        LogList.Children.Clear();
        LogList.Children.Add(new TextBlock
        {
            Text = "NO LOGS YET.",
            FontSize = 12,
            Foreground = Theme.DimGreenBrush,
            TextWrapping = TextWrapping.Wrap
        });
        Flash("CLEARED");
    }

    private void Flash(string message)
    {
        ActionNote.Text = message;
        ActionNote.Visibility = Visibility.Visible;
        flashTimer.Stop();
        flashTimer.Start();
    }
}
