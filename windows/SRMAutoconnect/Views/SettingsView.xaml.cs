using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using SRMAutoconnect.Core;
using SRMAutoconnect.Helpers;

namespace SRMAutoconnect.Views;

public partial class SettingsView : UserControl
{
    private bool hasStoredPassword;
    private bool loadingSettings;

    public SettingsView()
    {
        InitializeComponent();
        Loaded += (_, _) => LoadCredentials();
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var username = UsernameBox.Text.Trim();
            if (string.IsNullOrEmpty(username))
            {
                throw new InvalidOperationException("Enter your SRM ID first.");
            }

            var keepExistingPassword = string.IsNullOrEmpty(PasswordBox.Password);
            if (keepExistingPassword && !hasStoredPassword)
            {
                throw new InvalidOperationException("Enter your password first.");
            }

            var usernameData = Encoding.UTF8.GetBytes(username);
            CredentialStore.Shared.Save(usernameData, CredentialStore.UsernameTarget);

            byte[]? passwordData = null;
            if (!keepExistingPassword)
            {
                passwordData = Encoding.UTF8.GetBytes(PasswordBox.Password);
                CredentialStore.Shared.Save(passwordData, CredentialStore.PasswordTarget);
            }

            VerifySavedCredentials(usernameData, passwordData, keepExistingPassword);

            UsernameBox.Text = username;
            PasswordBox.Clear();
            hasStoredPassword = true;
            UpdatePasswordHint();

            var message = keepExistingPassword
                ? "SRM ID SAVED. PASSWORD UNCHANGED."
                : "CREDENTIALS SAVED SECURELY.";
            ShowNotice(message, Theme.GreenBrush);
            Logger.Shared.Log(keepExistingPassword
                ? "SRM ID saved; stored password left unchanged."
                : "Credentials saved securely.");
            AutoConnectManager.Shared.CredentialsChanged();
        }
        catch (Exception ex)
        {
            var message = $"SAVE FAILED: {ex.Message}";
            ShowNotice(message, Brushes.Red);
            Logger.Shared.Log(message);
        }
    }

    private void Forget_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            CredentialStore.Shared.Delete(CredentialStore.UsernameTarget);
            CredentialStore.Shared.Delete(CredentialStore.PasswordTarget);
            UsernameBox.Clear();
            PasswordBox.Clear();
            hasStoredPassword = false;
            UpdatePasswordHint();
            ShowNotice("SAVED CREDENTIALS REMOVED.", Theme.AmberBrush);
            Logger.Shared.Log("Saved credentials removed from Windows Credential Manager.");
            AutoConnectManager.Shared.CredentialsChanged();
        }
        catch (Exception ex)
        {
            var message = $"REMOVE FAILED: {ex.Message}";
            ShowNotice(message, Brushes.Red);
            Logger.Shared.Log(message);
        }
    }

    private void Quit_Click(object sender, RoutedEventArgs e)
    {
        Application.Current.Shutdown();
    }

    private void LoadCredentials()
    {
        try
        {
            loadingSettings = true;
            var usernameData = CredentialStore.Shared.Read(CredentialStore.UsernameTarget);
            if (usernameData is not null)
            {
                UsernameBox.Text = Encoding.UTF8.GetString(usernameData);
            }

            hasStoredPassword = CredentialStore.Shared.Read(CredentialStore.PasswordTarget) is not null;
            PasswordBox.Clear();
            UpdatePasswordHint();
            OpenAtLoginCheckBox.IsChecked = StartupService.Shared.IsEnabled();
        }
        catch (Exception ex)
        {
            ShowNotice($"CREDENTIALS: {ex.Message}", Brushes.Red);
            Logger.Shared.Log($"Cannot read saved credentials: {ex.Message}");
        }
        finally
        {
            loadingSettings = false;
        }
    }

    private void OpenAtLoginCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (loadingSettings)
        {
            return;
        }

        var enabled = OpenAtLoginCheckBox.IsChecked == true;
        try
        {
            StartupService.Shared.SetEnabled(enabled);
            ShowNotice(enabled ? "OPEN AT LOGIN ENABLED." : "OPEN AT LOGIN DISABLED.", Theme.GreenBrush);
        }
        catch (Exception ex)
        {
            loadingSettings = true;
            OpenAtLoginCheckBox.IsChecked = StartupService.Shared.IsEnabled();
            loadingSettings = false;
            var message = $"OPEN AT LOGIN FAILED: {ex.Message}";
            ShowNotice(message, Brushes.Red);
            Logger.Shared.Log(message);
        }
    }

    private static void VerifySavedCredentials(byte[] usernameData, byte[]? passwordData, bool keepExistingPassword)
    {
        var savedUsername = CredentialStore.Shared.Read(CredentialStore.UsernameTarget);
        if (savedUsername is null || !savedUsername.SequenceEqual(usernameData))
        {
            throw new InvalidOperationException("Write succeeded but SRM ID read-back differed.");
        }

        var savedPassword = CredentialStore.Shared.Read(CredentialStore.PasswordTarget);
        if (keepExistingPassword)
        {
            if (savedPassword is null)
            {
                throw new InvalidOperationException("Stored password was missing after save.");
            }
        }
        else if (passwordData is null || savedPassword is null || !savedPassword.SequenceEqual(passwordData))
        {
            throw new InvalidOperationException("Write succeeded but password read-back differed.");
        }
    }

    private void UpdatePasswordHint()
    {
        PasswordHintText.Text = hasStoredPassword
            ? "Saved - leave blank to keep current password"
            : "Enter Password";
    }

    private void ShowNotice(string message, Brush brush)
    {
        SaveNotice.Text = message;
        SaveNotice.Foreground = brush;
        SaveNotice.Visibility = Visibility.Visible;
    }
}
