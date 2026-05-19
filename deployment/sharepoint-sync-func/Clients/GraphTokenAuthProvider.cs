using System.Net.Http.Headers;
using Azure.Core;

namespace SharePointSyncFunc.Clients;

/// <summary>
/// Adds bearer token to outbound HTTP requests using a TokenCredential.
/// Used for direct Graph delta API calls that require custom headers (e.g. Prefer:).
/// </summary>
public sealed class GraphTokenAuthHandler : DelegatingHandler
{
    private readonly TokenCredential _credential;
    private static readonly string[] Scopes = { "https://graph.microsoft.com/.default" };

    public GraphTokenAuthHandler(TokenCredential credential)
    {
        _credential = credential;
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        var token = await _credential.GetTokenAsync(
            new TokenRequestContext(Scopes), cancellationToken).ConfigureAwait(false);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        return await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
    }
}
