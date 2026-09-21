using Microsoft.Win32;

namespace SRMAutoconnect.Core;

public sealed class StartupService
{
    public static StartupService Shared { get; } = new();

    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "SRMAutoconnect";

    private StartupService()
    {
    }

    public bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(ValueName) is string value && !string.IsNullOrWhiteSpace(value);
    }

    public void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
            ?? throw new InvalidOperationException("Could not open Windows Run registry key.");

        if (enabled)
        {
            var executablePath = Environment.ProcessPath
                ?? throw new InvalidOperationException("Could not determine the application executable path.");
            key.SetValue(ValueName, $"\"{executablePath}\"", RegistryValueKind.String);
            Logger.Shared.Log($"Enabled Open at Login: {executablePath}");
        }
        else
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
            Logger.Shared.Log("Disabled Open at Login.");
        }
    }
}
