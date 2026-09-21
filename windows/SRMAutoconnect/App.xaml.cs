using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using Hardcodet.Wpf.TaskbarNotification;
using SRMAutoconnect.Core;
using SRMAutoconnect.Views;

namespace SRMAutoconnect;

public partial class App : Application
{
    private TaskbarIcon? trayIcon;
    private MainPopup? popup;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        Logger.Shared.Log("Windows UI shell ready.");
        Logger.Shared.Debug($"Log file: {Logger.Shared.LogFilePath}");
        _ = NetworkMonitor.Shared;
        _ = AutoConnectManager.Shared;
        AutoConnectManager.Shared.PrewarmWebView();

        trayIcon = new TaskbarIcon
        {
            ContextMenu = BuildContextMenu()
        };
        trayIcon.TrayLeftMouseUp += (_, _) => TogglePopup();
        NetworkMonitor.Shared.PropertyChanged += (_, _) => UpdateTrayIcon();
        AutoConnectManager.Shared.PropertyChanged += (_, _) => UpdateTrayIcon();
        NotificationService.Shared.NotificationRequested += HandleNotificationRequested;
        UpdateTrayIcon();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        trayIcon?.Dispose();
        NetworkMonitor.Shared.Dispose();
        AutoConnectManager.Shared.Dispose();
        ReachabilityProbe.Shared.Dispose();
        Logger.Shared.Dispose();
        base.OnExit(e);
    }

    private ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();
        menu.Items.Add(MenuItem("Open SRM Autoconnect", (_, _) => ShowPopup()));
        menu.Items.Add(MenuItem("Force Connect", (_, _) => AutoConnectManager.Shared.AttemptLogin(force: true)));
        menu.Items.Add(MenuItem("Reveal Log File", (_, _) => RevealLogFile()));
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

    private void HandleNotificationRequested(object? sender, NotificationRequest request)
    {
        trayIcon?.ShowBalloonTip(request.Title, request.Message, BalloonIcon.Info);
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

    private static Icon LoadTrayIcon(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", "tray-icons", fileName);
        return File.Exists(path) ? new Icon(path) : SystemIcons.Application;
    }

    private void UpdateTrayIcon()
    {
        if (trayIcon is null)
        {
            return;
        }

        var monitor = NetworkMonitor.Shared;
        var manager = AutoConnectManager.Shared;
        if (manager.IsConnecting)
        {
            trayIcon.Icon = LoadTrayIcon("connecting.ico");
            trayIcon.ToolTipText = "SRM Autoconnect - logging in";
        }
        else if (manager.LastResult == LoginResult.Failure)
        {
            trayIcon.Icon = LoadTrayIcon("failed.ico");
            trayIcon.ToolTipText = "SRM Autoconnect - login failed";
        }
        else if (monitor.IsConnectedToSRM)
        {
            trayIcon.Icon = LoadTrayIcon("connected.ico");
            trayIcon.ToolTipText = $"SRM Autoconnect - on {monitor.CurrentSSID}";
        }
        else
        {
            trayIcon.Icon = LoadTrayIcon("not-on-srmist.ico");
            trayIcon.ToolTipText = "SRM Autoconnect - not on SRMIST";
        }
    }

    private static void RevealLogFile()
    {
        var path = Logger.Shared.LogFilePath;
        var directory = Path.GetDirectoryName(path);
        if (string.IsNullOrWhiteSpace(directory))
        {
            return;
        }

        Directory.CreateDirectory(directory);
        if (!File.Exists(path))
        {
            File.WriteAllText(path, string.Empty);
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"/select,\"{path}\"",
            UseShellExecute = true
        });
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

