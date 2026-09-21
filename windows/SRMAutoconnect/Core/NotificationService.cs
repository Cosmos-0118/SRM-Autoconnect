using System.Media;

namespace SRMAutoconnect.Core;

public sealed class NotificationService
{
    public static NotificationService Shared { get; } = new();

    public event EventHandler<NotificationRequest>? NotificationRequested;

    private NotificationService()
    {
    }

    public void ShowConnectedToast()
    {
        try
        {
            NotificationRequested?.Invoke(
                this,
                new NotificationRequest("Connected to SRM Wi-Fi", "You're all set."));
            Logger.Shared.Debug("Connected notification requested.");
        }
        catch (Exception ex)
        {
            Logger.Shared.Log($"Failed to show connected notification: {ex.Message}");
        }

        try
        {
            SystemSounds.Asterisk.Play();
        }
        catch (Exception ex)
        {
            Logger.Shared.Log($"Failed to play connected sound: {ex.Message}");
        }
    }
}

public sealed record NotificationRequest(string Title, string Message);
