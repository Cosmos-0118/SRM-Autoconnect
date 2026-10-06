// Isolate the production login manager from real credentials and network probes.
using System.Text;

namespace SRMAutoconnect.Core;

public sealed class Logger
{
    public static Logger Shared { get; } = new();
    public bool DebugEnabled { get; set; }
    public void Debug(string message) { }
    public void Log(string message) => Console.WriteLine(message);
}

public sealed class CredentialStore
{
    public const string UsernameTarget = "username";
    public const string PasswordTarget = "password";
    public static CredentialStore Shared { get; } = new();
    public byte[] Read(string target) => Encoding.UTF8.GetBytes(target == UsernameTarget ? "fixture-user" : "fixture-password");
}

public sealed record Reachability(bool Online, bool CaptivePortal, string Detail);
public sealed class ReachabilityProbe
{
    public static ReachabilityProbe Shared { get; } = new();
    public Func<Task<bool>> IsOnline { get; set; } = () => Task.FromResult(false);
    public int Calls { get; private set; }
    public void Reset() => Calls = 0;
    public async Task<Reachability> ProbeReachabilityAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Calls++;
        return new Reachability(await IsOnline(), true, "controlled fixture probe");
    }
}

public sealed class NetworkMonitor
{
    public static NetworkMonitor Shared { get; } = new();
    public bool IsConnectedToSRM { get; set; } = true;
    public bool IsReadyForAutomaticLogin { get; set; } = true;
}

public sealed class NotificationService
{
    public static NotificationService Shared { get; } = new();
    public void ShowConnectedToast() { }
}
