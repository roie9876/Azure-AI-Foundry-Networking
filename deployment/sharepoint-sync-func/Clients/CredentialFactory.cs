using System;
using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Logging;

namespace SharePointSyncFunc.Clients;

/// <summary>
/// Builds Azure credentials following the same precedence as the original Python code:
/// - SharePoint/Graph: explicit ClientSecret when AZURE_CLIENT_ID/SECRET/TENANT_ID set,
///   otherwise DefaultAzureCredential (Managed Identity / az CLI / etc.)
/// - Storage: separate AZURE_STORAGE_* env vars take precedence; in Azure (IDENTITY_ENDPOINT)
///   uses ManagedIdentityCredential to avoid picking up the SharePoint app registration;
///   locally falls back to AzureCliCredential.
/// </summary>
public static class CredentialFactory
{
    public static TokenCredential GetSharePointCredential(ILogger? logger = null)
    {
        var clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID");
        var clientSecret = Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET");
        var tenantId = Environment.GetEnvironmentVariable("AZURE_TENANT_ID");

        if (!string.IsNullOrWhiteSpace(clientId) &&
            !string.IsNullOrWhiteSpace(clientSecret) &&
            !string.IsNullOrWhiteSpace(tenantId))
        {
            logger?.LogInformation("Using ClientSecretCredential for SharePoint (App Registration tenant={TenantId} client={ClientId})", tenantId, clientId);
            return new ClientSecretCredential(tenantId, clientId, clientSecret);
        }

        if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("IDENTITY_ENDPOINT")))
        {
            logger?.LogInformation("Using DefaultAzureCredential (Managed Identity) for SharePoint");
            return new DefaultAzureCredential();
        }

        logger?.LogInformation("Using DefaultAzureCredential for SharePoint (Azure CLI / PowerShell)");
        return new DefaultAzureCredential();
    }

    public static TokenCredential GetBlobCredential(ILogger? logger = null)
    {
        var storageTenantId = Environment.GetEnvironmentVariable("AZURE_STORAGE_TENANT_ID");
        var storageClientId = Environment.GetEnvironmentVariable("AZURE_STORAGE_CLIENT_ID");
        var storageClientSecret = Environment.GetEnvironmentVariable("AZURE_STORAGE_CLIENT_SECRET");

        if (!string.IsNullOrWhiteSpace(storageTenantId) &&
            !string.IsNullOrWhiteSpace(storageClientId) &&
            !string.IsNullOrWhiteSpace(storageClientSecret))
        {
            logger?.LogInformation("Using ClientSecretCredential for Blob Storage (tenant={TenantId} client={ClientId})", storageTenantId, storageClientId);
            return new ClientSecretCredential(storageTenantId, storageClientId, storageClientSecret);
        }

        if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("IDENTITY_ENDPOINT")))
        {
            logger?.LogInformation("Using ManagedIdentityCredential for Blob Storage");
            // System-assigned managed identity. Azure.Identity 1.21+ deprecated the
            // legacy (string clientId, TokenCredentialOptions) overload; we use the
            // typed ManagedIdentityId factory instead.
            return new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned);
        }

        logger?.LogInformation("Using AzureCliCredential for Blob Storage");
        return new AzureCliCredential();
    }
}
