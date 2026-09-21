using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;

namespace SRMAutoconnect.Core;

public sealed record Reachability(bool Online, bool CaptivePortal, string Detail);

public sealed class ReachabilityProbe : IDisposable
{
    public static ReachabilityProbe Shared { get; } = new();

    private const int CanaryQuorum = 2;

    private static readonly ProbeDefinition[] Canaries =
    [
        new("example.com", new Uri("https://example.com"), "Example Domain"),
        new("cloudflare.com", new Uri("https://cloudflare.com/cdn-cgi/trace"), "fl="),
        new("mozilla.org", new Uri("https://www.mozilla.org/robots.txt"), "user-agent")
    ];

    private static readonly ProbeDefinition AppleCaptivePortal =
        new("apple-captive", new Uri("http://captive.apple.com/hotspot-detect.html"), null);

    private readonly HttpClient httpClient;

    private ReachabilityProbe()
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5)
        };

        httpClient = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(8)
        };
    }

    public async Task<Reachability> ProbeReachabilityAsync(CancellationToken cancellationToken = default)
    {
        Logger.Shared.Debug("Reachability: starting canary probe.");

        var canaryTasks = Canaries.Select(definition => ProbeAsync(definition, cancellationToken)).ToArray();
        var appleTask = ProbeAsync(AppleCaptivePortal, cancellationToken);

        var canaryResults = await Task.WhenAll(canaryTasks);
        var appleResult = await appleTask;

        var successes = canaryResults.Count(result => result.Ok);
        var successfulNames = canaryResults
            .Where(result => result.Ok)
            .Select(result => result.Name)
            .ToArray();

        var online = successes >= CanaryQuorum;
        var portalIntercept = IsAppleCaptivePortalIntercept(appleResult);
        var detail = $"{successes}/{Canaries.Length} canaries ok"
            + (successfulNames.Length == 0 ? string.Empty : $" [{string.Join(", ", successfulNames)}]")
            + (portalIntercept ? ", portal intercepting" : string.Empty);

        Logger.Shared.Debug($"Reachability: {(online ? "online" : "offline")} - {detail}");
        return new Reachability(online, portalIntercept && !online, detail);
    }

    public void Dispose()
    {
        httpClient.Dispose();
    }

    private async Task<ProbeResult> ProbeAsync(ProbeDefinition definition, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(6));

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, definition.Url);
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
            request.Headers.Pragma.ParseAdd("no-cache");
            request.Headers.UserAgent.ParseAdd("SRMAutoconnect/1.0");

            using var response = await httpClient.SendAsync(request, HttpCompletionOption.ResponseContentRead, timeout.Token);
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
                : $"Reachability probe {definition.Name}: failed (HTTP {status}, expected '{definition.ExpectedText ?? "2xx"}', {body.Length} bytes).");

            return new ProbeResult(
                definition.Name,
                ok,
                status,
                body,
                response.Headers.Location?.ToString(),
                Error: null);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            Logger.Shared.Debug($"Reachability probe {definition.Name}: timed out after 6s.");
            return new ProbeResult(definition.Name, false, StatusCode: null, Body: null, RedirectLocation: null, Error: "timeout");
        }
        catch (Exception ex)
        {
            Logger.Shared.Debug($"Reachability probe {definition.Name}: error - {ex.GetType().Name}: {ex.Message}");
            return new ProbeResult(definition.Name, false, StatusCode: null, Body: null, RedirectLocation: null, Error: ex.Message);
        }
    }

    private static bool IsAppleCaptivePortalIntercept(ProbeResult result)
    {
        if (result.StatusCode is >= 300 and <= 399)
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

    private sealed record ProbeDefinition(string Name, Uri Url, string? ExpectedText);

    private sealed record ProbeResult(
        string Name,
        bool Ok,
        int? StatusCode,
        string? Body,
        string? RedirectLocation,
        string? Error);
}
