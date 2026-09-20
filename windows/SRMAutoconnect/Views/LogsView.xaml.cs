using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using SRMAutoconnect.Core;

namespace SRMAutoconnect.Views;

public partial class LogsView : UserControl
{
    private readonly DispatcherTimer flashTimer;

    public LogsView()
    {
        InitializeComponent();
        DataContext = Logger.Shared;

        flashTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.6) };
        flashTimer.Tick += (_, _) =>
        {
            flashTimer.Stop();
            ActionNote.Visibility = Visibility.Collapsed;
        };

        Logger.Shared.Logs.CollectionChanged += Logs_CollectionChanged;
        UpdateEmptyState();
    }

    private void CopyLogs_Click(object sender, RoutedEventArgs e)
    {
        var lines = Logger.Shared.Logs.Select(entry => entry.Text).ToArray();
        if (lines.Length == 0)
        {
            Flash("NO LOGS");
            return;
        }

        Clipboard.SetText(string.Join(Environment.NewLine, lines));
        Flash($"COPIED {lines.Length}");
    }

    private void ClearLogs_Click(object sender, RoutedEventArgs e)
    {
        Logger.Shared.ClearUiLogs();
        Flash("CLEARED");
    }

    private void Logs_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        UpdateEmptyState();
    }

    private void UpdateEmptyState()
    {
        EmptyLogText.Visibility = Logger.Shared.Logs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Flash(string message)
    {
        ActionNote.Text = message;
        ActionNote.Visibility = Visibility.Visible;
        flashTimer.Stop();
        flashTimer.Start();
    }
}
