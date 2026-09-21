using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using ManagedNativeWifi;

namespace SRMAutoconnect.Core;

public sealed record Reachability(bool Online, bool CaptivePortal, string Detail);

public sealed class ReachabilityProbe : IDisposable
{
    public static ReachabilityProbe Shared { get; } = new();

    private const int CanaryQuorum = 3;
    private const string BrowserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";

    /// <summary>
    /// HTTPS canaries prove a real origin answered with a valid certificate. They
    /// are not sufficient on their own: enterprise NACs routinely allow-list
    /// popular HTTPS hosts and OS connectivity-check domains before login.
    /// </summary>
    private static readonly ProbeDefinition[] HttpsCanaries =
    [
        new("example.com", new Uri("https://example.com"), "Example Domain", "example.com"),
        new("cloudflare.com", new Uri("https://cloudflare.com/cdn-cgi/trace"), "fl=", "cloudflare.com"),
        new("mozilla.org", new Uri("https://www.mozilla.org/robots.txt"), "user-agent: *", "www.mozilla.org"),
        new("wikipedia.org", new Uri("https://en.wikipedia.org/robots.txt"), "robots.txt for http://www.wikipedia.org", "en.wikipedia.org")
    ];

    /// <summary>
    /// Ordinary HTTP hosts, not Apple/Microsoft/Google captive-detect URLs. A
    /// walled garden must intercept these to show a login page; same-host HTTPS
    /// upgrades are allowed, off-host redirects and unexpected bodies are not.
    /// </summary>
    private static readonly ProbeDefinition[] HttpIdentityProbes =
    [
        new("example-http", new Uri("http://example.com/"), "Example Domain", "example.com"),
        new("httpforever", new Uri("http://httpforever.com/"), "HTTP Forever", "httpforever.com")
    ];

    private static readonly ProbeDefinition AppleCaptivePortal =
        new("apple-captive", new Uri("http://captive.apple.com/hotspot-detect.html"), null, "captive.apple.com");

    private readonly object clientLock = new();
    private HttpClient? httpClient;
    private string? boundClientKey;
    private bool disposed;

    public async Task<Reachability> ProbeReachabilityAsync(CancellationToken cancellationToken = default)
    {
        var localAddress = GetWifiIpv4Address();
        var client = GetClient(localAddress);
        Logger.Shared.Debug($"Reachability: starting probe (via {localAddress?.ToString() ?? "default route"}).");

        var httpsTasks = HttpsCanaries.Select(definition => ProbeAsync(client, definition, cancellationToken)).ToArray();
        var httpTasks = HttpIdentityProbes.Select(definition => ProbeAsync(client, definition, cancellationToken)).ToArray();
        var appleTask = ProbeAsync(client, AppleCaptivePortal, cancellationToken);
        var dnsHijackTask = ProbeDnsHijackAsync(client, cancellationToken);

        var httpsResults = await Task.WhenAll(httpsTasks);
        var httpResults = await Task.WhenAll(httpTasks);
        var appleResult = await appleTask;
        var dnsHijacked = await dnsHijackTask;

        var interceptReasons = new List<string>();
        if (dnsHijacked)
        {
            interceptReasons.Add("DNS hijack");
        }

        foreach (var result in httpResults)
        {
            if (IsOffHostRedirect(result))
            {
                interceptReasons.Add($"{result.Name} redirected to {HostOf(result.RedirectLocation) ?? "(unknown)"}");
            }
            else if (result.StatusCode is >= 200 and <= 299 && !result.Ok)
            {
                interceptReasons.Add($"{result.Name} served unexpected body");
            }
        }

        var appleIntercept = IsAppleCaptivePortalIntercept(appleResult);
        if (appleIntercept)
        {
            interceptReasons.Add("Apple captive probe intercepted");
        }

        var successes = httpsResults.Count(result => result.Ok);
        var successfulNames = httpsResults
            .Where(result => result.Ok)
            .Select(result => result.Name)
            .ToArray();
        var httpIdentityOk = httpResults.Count(result => result.Ok);
        var intercepted = interceptReasons.Count > 0;
        var online = successes >= CanaryQuorum
            && httpIdentityOk >= HttpIdentityProbes.Length
            && !intercepted;
        var detail = $"{successes}/{HttpsCanaries.Length} canaries ok"
            + (successfulNames.Length == 0 ? string.Empty : $" [{string.Join(", ", successfulNames)}]")
            + $", {httpIdentityOk}/{HttpIdentityProbes.Length} HTTP identity ok"
            + (intercepted ? $", portal intercepting ({string.Join("; ", interceptReasons)})" : string.Empty);

        Logger.Shared.Debug($"Reachability: {(online ? "online" : "offline")} - {detail}");
        return new Reachability(online, intercepted && !online, detail);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        lock (clientLock)
        {
            httpClient?.Dispose();
            httpClient = null;
        }
    }

    private HttpClient GetClient(IPAddress? localAddress)
    {
        var key = localAddress?.ToString() ?? "default";
        lock (clientLock)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (httpClient is not null && boundClientKey == key)
            {
                return httpClient;
            }

            httpClient?.Dispose();
            boundClientKey = key;
            httpClient = CreateClient(localAddress);
            return httpClient;
        }
    }

    private static HttpClient CreateClient(IPAddress? localAddress)
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(6),
            PooledConnectionLifetime = TimeSpan.Zero,
            PooledConnectionIdleTimeout = TimeSpan.Zero,
            ConnectCallback = async (context, cancellationToken) =>
            {
                var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
                try
                {
                    if (localAddress is not null)
                    {
                        socket.Bind(new IPEndPoint(localAddress, 0));
                    }

                    await socket.ConnectAsync(context.DnsEndPoint, cancellationToken).ConfigureAwait(false);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
            }
        };

        return new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(8)
        };
    }

    private static IPAddress? GetWifiIpv4Address()
    {
        Guid? srmInterfaceId = null;
        try
        {
            foreach (var iface in NativeWifi.EnumerateInterfaces())
            {
                var (result, connection) = NativeWifi.GetCurrentConnection(iface.Id);
                if (result != ActionResult.Success)
                {
                    continue;
                }

                var ssid = connection.Ssid?.ToString() ?? string.Empty;
                if (NetworkMonitor.IsSRMNetwork(ssid))
                {
                    srmInterfaceId = iface.Id;
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            Logger.Shared.Debug($"Could not map SRMIST to a Wi-Fi interface: {ex.Message}");
        }

        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up
                || nic.NetworkInterfaceType != NetworkInterfaceType.Wireless80211)
            {
                continue;
            }

            if (srmInterfaceId is { } id)
            {
                if (!Guid.TryParse(nic.Id, out var nicId) || nicId != id)
                {
                    continue;
                }
            }

            var ipv4 = nic.GetIPProperties().UnicastAddresses
                .Select(address => address.Address)
                .FirstOrDefault(address => address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address));
            if (ipv4 is not null)
            {
                return ipv4;
            }
        }

        return null;
    }

    private static async Task<bool> ProbeDnsHijackAsync(HttpClient client, CancellationToken cancellationToken)
    {
        var host = $"srm-{Guid.NewGuid():N}.invalid";
        var result = await ProbeAsync(
            client,
            new ProbeDefinition("dns-hijack", new Uri($"http://{host}/"), null, host),
            cancellationToken);

        if (result.StatusCode is not null || result.RedirectLocation is not null)
        {
            Logger.Shared.Debug($"Reachability probe dns-hijack: resolver returned an HTTP response for '{host}'.");
            return true;
        }

        return false;
    }

    private static async Task<ProbeResult> ProbeAsync(
        HttpClient client,
        ProbeDefinition definition,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(6));

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, definition.Url);
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
            request.Headers.Pragma.ParseAdd("no-cache");
            request.Headers.ConnectionClose = true;
            request.Headers.TryAddWithoutValidation("User-Agent", BrowserUserAgent);

            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseContentRead, timeout.Token);
            var status = (int)response.StatusCode;
            var body = response.Content is null
                ? string.Empty
                : await response.Content.ReadAsStringAsync(timeout.Token);

            var statusOk = response.StatusCode is >= HttpStatusCode.OK and <= (HttpStatusCode)299;
            var expectedOk = definition.ExpectedText is null
                || body.Contains(definition.ExpectedText, StringComparison.OrdinalIgnoreCase);
            var ok = statusOk && expectedOk;

            Logger.Shared.Debug(ok
                ? $"Reachability probe {definition.Name}: ok (HTTP {status}, {body.Length} bytes)."
                : $"Reachability probe {definition.Name}: failed (HTTP {status}, expected '{definition.ExpectedText ?? "2xx"}', {body.Length} bytes, location '{response.Headers.Location}').");

            return new ProbeResult(
                definition.Name,
                ok,
                status,
                body,
                response.Headers.Location?.ToString(),
                definition.ExpectedHost,
                Error: null);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            Logger.Shared.Debug($"Reachability probe {definition.Name}: timed out after 6s.");
            return new ProbeResult(definition.Name, false, StatusCode: null, Body: null, RedirectLocation: null, definition.ExpectedHost, Error: "timeout");
        }
        catch (Exception ex)
        {
            Logger.Shared.Debug($"Reachability probe {definition.Name}: error - {ex.GetType().Name}: {ex.Message}");
            return new ProbeResult(definition.Name, false, StatusCode: null, Body: null, RedirectLocation: null, definition.ExpectedHost, Error: ex.Message);
        }
    }

    private static bool IsOffHostRedirect(ProbeResult result)
    {
        if (result.StatusCode is not (>= 300 and <= 399) || string.IsNullOrWhiteSpace(result.RedirectLocation))
        {
            return false;
        }

        if (!Uri.TryCreate(result.RedirectLocation, UriKind.Absolute, out var location))
        {
            return true;
        }

        return !HostMatches(location.Host, result.ExpectedHost);
    }

    private static bool IsAppleCaptivePortalIntercept(ProbeResult result)
    {
        if (IsOffHostRedirect(result) || result.StatusCode is >= 300 and <= 399)
        {
            Logger.Shared.Debug($"Apple captive probe redirected to '{result.RedirectLocation ?? "(unknown)"}'.");
            return true;
        }

        if (result.StatusCode is >= 200 and <= 299)
        {
            return result.Body?.Contains("Success", StringComparison.OrdinalIgnoreCase) == false;
        }

        return false;
    }

    private static bool HostMatches(string host, string expectedHost)
    {
        if (host.Equals(expectedHost, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return host.Equals("www." + expectedHost, StringComparison.OrdinalIgnoreCase)
            || expectedHost.Equals("www." + host, StringComparison.OrdinalIgnoreCase);
    }

    private static string? HostOf(string? location)
    {
        return Uri.TryCreate(location, UriKind.Absolute, out var uri) ? uri.Host : location;
    }

    private sealed record ProbeDefinition(string Name, Uri Url, string? ExpectedText, string ExpectedHost);

    private sealed record ProbeResult(
        string Name,
        bool Ok,
        int? StatusCode,
        string? Body,
        string? RedirectLocation,
        string ExpectedHost,
        string? Error);
}
