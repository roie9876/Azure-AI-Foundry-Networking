using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using SharePointSyncFunc.Models;

namespace SharePointSyncFunc.Clients;

/// <summary>
/// File-system delta token persistence (mirrors Python DeltaTokenStorage). Used by
/// the optional graph-delta permissions/files clients.
/// </summary>
public sealed class DeltaTokenStorage
{
    private readonly string _storagePath;
    private readonly ILogger? _logger;

    public DeltaTokenStorage(string storagePath, ILogger? logger = null)
    {
        _storagePath = storagePath;
        _logger = logger;
        Directory.CreateDirectory(_storagePath);
    }

    private string GetTokenFilePath(string driveId, string tokenType)
    {
        var safeId = driveId.Replace("!", "_").Replace(",", "_");
        return Path.Combine(_storagePath, $"delta_token_{tokenType}_{safeId}.json");
    }

    public DeltaToken? GetToken(string driveId, string tokenType = "files")
    {
        var path = GetTokenFilePath(driveId, tokenType);
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            var raw = File.ReadAllText(path);
            var doc = JsonSerializer.Deserialize<DeltaTokenDto>(raw);
            if (doc is null)
            {
                return null;
            }

            return new DeltaToken
            {
                DriveId = doc.DriveId ?? string.Empty,
                Token = doc.Token ?? string.Empty,
                LastUpdated = DateTimeOffset.TryParse(doc.LastUpdated, out var parsed)
                    ? parsed
                    : DateTimeOffset.UtcNow,
                TokenType = string.IsNullOrEmpty(doc.TokenType) ? "files" : doc.TokenType,
            };
        }
        catch (Exception ex)
        {
            _logger?.LogWarning("Failed to load delta token (path={Path}, error={Error})", path, ex.Message);
            return null;
        }
    }

    public void SaveToken(DeltaToken token)
    {
        var path = GetTokenFilePath(token.DriveId, token.TokenType);
        var dto = new DeltaTokenDto
        {
            DriveId = token.DriveId,
            Token = token.Token,
            LastUpdated = token.LastUpdated.ToString("o"),
            TokenType = token.TokenType,
        };
        File.WriteAllText(path, JsonSerializer.Serialize(dto, new JsonSerializerOptions { WriteIndented = true }));
        _logger?.LogInformation("Saved delta token (drive_id={DriveId}, token_type={TokenType}, path={Path})",
            token.DriveId, token.TokenType, path);
    }

    public void DeleteToken(string driveId, string tokenType = "files")
    {
        var path = GetTokenFilePath(driveId, tokenType);
        if (File.Exists(path))
        {
            File.Delete(path);
            _logger?.LogInformation("Deleted delta token (drive_id={DriveId}, token_type={TokenType})", driveId, tokenType);
        }
    }

    private sealed class DeltaTokenDto
    {
        [JsonPropertyName("drive_id")] public string? DriveId { get; set; }
        [JsonPropertyName("token")] public string? Token { get; set; }
        [JsonPropertyName("last_updated")] public string? LastUpdated { get; set; }
        [JsonPropertyName("token_type")] public string? TokenType { get; set; }
    }
}
