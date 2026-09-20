using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using Hardcodet.Wpf.TaskbarNotification;
using SRMAutoconnect.Views;

namespace SRMAutoconnect;

public partial class App : Application
{
    private TaskbarIcon? trayIcon;
    private MainPopup? popup;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        trayIcon = new TaskbarIcon
        {
            Icon = SystemIcons.Application,
            ToolTipText = "SRM Autoconnect - Windows scaffold",
            ContextMenu = BuildContextMenu()
        };
        trayIcon.TrayLeftMouseUp += (_, _) => TogglePopup();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        trayIcon?.Dispose();
        base.OnExit(e);
    }

    private ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();
        menu.Items.Add(MenuItem("Open SRM Autoconnect", (_, _) => ShowPopup()));
        menu.Items.Add(MenuItem("Force Connect", (_, _) => ShowPhaseNotice("Force Connect")));
        menu.Items.Add(MenuItem("Reveal Log File", (_, _) => ShowPhaseNotice("Reveal Log File")));
        menu.Items.Add(new Separator());
        menu.Items.Add(MenuItem("Quit SRM Autoconnect", (_, _) => Shutdown()));
        return menu;
    }

    private static MenuItem MenuItem(string header, RoutedEventHandler click)
    {
        var item = new MenuItem { Header = header };
        item.Click += click;
        return item;
    }

    private void TogglePopup()
    {
        if (popup?.IsVisible == true)
        {
            popup.Hide();
            return;
        }

        ShowPopup();
    }

    private void ShowPopup()
    {
        popup ??= new MainPopup();
        PositionPopupNearTray();
        popup.Show();
        popup.Activate();
    }

    private void PositionPopupNearTray()
    {
        if (popup is null)
        {
            return;
        }

        _ = GetCursorPos(out var cursor);
        var workArea = SystemParameters.WorkArea;
        var left = cursor.X - (popup.Width / 2);
        var top = cursor.Y - popup.Height - 12;

        popup.Left = Math.Clamp(left, workArea.Left, workArea.Right - popup.Width);
        popup.Top = Math.Clamp(top, workArea.Top, workArea.Bottom - popup.Height);
    }

    private static void ShowPhaseNotice(string action)
    {
        MessageBox.Show(
            $"{action} will be wired in a later phase.",
            "SRM Autoconnect",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT point);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }
}

