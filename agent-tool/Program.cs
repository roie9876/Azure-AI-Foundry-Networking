using Azure;
using Azure.AI.Projects;
using Azure.AI.Projects.OpenAI;
using Azure.Core;
using Azure.Identity;
using Azure.Search.Documents;
using Azure.Search.Documents.Models;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

// ---------------------------------------------------------------------------
// Foundry Agent v2 creation tool.
//
// Uses Azure.AI.Projects SDK 2.0 (v2 API) with PromptAgentDefinition.
//
// Modes:
//   Create: dotnet run -- --endpoint <url> --model gpt-4o
//                         --search-connection conn-search --index-name idx
//   Test:   dotnet run -- --endpoint <url> --test "query"
// ---------------------------------------------------------------------------

static string GetArg(string[] a, string name, string def = "")
{
    for (int i = 0; i < a.Length - 1; i++)
        if (a[i] == name) return a[i + 1];
    return def;
}

static List<string> ParsePrincipalIds(string raw)
{
    if (string.IsNullOrWhiteSpace(raw)) return new List<string>();
    return raw
        .Split(new[] { ',', ';', '|', ' ' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .ToList();
}

static string EscapeFilterLiteral(string value) => value.Replace("'", "''");

static string BuildAclFilter(IEnumerable<string> userIds, IEnumerable<string> groupIds)
{
    var clauses = new List<string>();

    foreach (var u in userIds)
    {
        clauses.Add($"search.ismatch('{EscapeFilterLiteral(u)}', 'acl_user_ids')");
    }

    foreach (var g in groupIds)
    {
        clauses.Add($"search.ismatch('{EscapeFilterLiteral(g)}', 'acl_group_ids')");
    }

    if (clauses.Count == 0)
    {
        throw new ArgumentException("At least one user ID or group ID is required for ACL trimming.");
    }

    return string.Join(" or ", clauses);
}

static string GetString(SearchDocument doc, string key)
{
    if (!doc.TryGetValue(key, out var value) || value is null)
    {
        return string.Empty;
    }

    return value.ToString() ?? string.Empty;
}

static SearchClient CreateSearchClient(string endpoint, string indexName, string searchKey, TokenCredential credential)
{
    if (string.IsNullOrWhiteSpace(searchKey))
    {
        return new SearchClient(new Uri(endpoint), indexName, credential);
    }

    return new SearchClient(new Uri(endpoint), indexName, new AzureKeyCredential(searchKey));
}

static async Task<List<SearchDocument>> QuerySearchWithAclAsync(
    SearchClient searchClient,
    string query,
    List<string> userIds,
    List<string> groupIds,
    int top)
{
    var aclFilter = BuildAclFilter(userIds, groupIds);

    var options = new SearchOptions
    {
        Size = top,
        IncludeTotalCount = true,
        Filter = aclFilter
    };
    options.Select.Add("title");
    options.Select.Add("content");
    options.Select.Add("acl_user_ids");
    options.Select.Add("acl_group_ids");

    var response = await searchClient.SearchAsync<SearchDocument>(query, options);
    var docs = new List<SearchDocument>();

    await foreach (var result in response.Value.GetResultsAsync())
    {
        docs.Add(result.Document);
    }

    return docs;
}

static string BuildAllowedDocsContext(List<SearchDocument> docs)
{
    if (docs.Count == 0)
    {
        return "No ACL-eligible documents were retrieved.";
    }

    var sb = new StringBuilder();
    for (int i = 0; i < docs.Count; i++)
    {
        var d = docs[i];
        var title = GetString(d, "title");
        var content = GetString(d, "content");
        if (content.Length > 1000)
        {
            content = content[..1000] + "...";
        }
        sb.AppendLine($"[{i + 1}] {title}");
        sb.AppendLine(content);
        sb.AppendLine();
    }
    return sb.ToString();
}

var endpoint       = GetArg(args, "--endpoint");
var model          = GetArg(args, "--model", "gpt-4o");
var searchConn     = GetArg(args, "--search-connection");
var indexName      = GetArg(args, "--index-name", "sharepoint-index");
var embeddingModel = GetArg(args, "--embedding-model", "text-embedding-3-large");
var agentName      = GetArg(args, "--agent-name", "sharepoint-knowledge-agent");
var testQuery      = GetArg(args, "--test");
var sample         = GetArg(args, "--sample");
var query          = GetArg(args, "--query", testQuery);
var searchEndpoint = GetArg(args, "--search-endpoint");
var searchKey      = GetArg(args, "--search-key");
var userIds        = ParsePrincipalIds(GetArg(args, "--user-ids"));
var groupIds       = ParsePrincipalIds(GetArg(args, "--group-ids"));
var topArg         = GetArg(args, "--top", "5");
var top            = int.TryParse(topArg, out var topParsed) ? Math.Max(1, topParsed) : 5;

if (string.IsNullOrEmpty(endpoint))
{
    Console.Error.WriteLine("Usage: dotnet run -- --endpoint <project-endpoint> [options]");
    Console.Error.WriteLine();
    Console.Error.WriteLine("  --endpoint <url>            Foundry project endpoint (required)");
    Console.Error.WriteLine("  --model <name>              Model deployment (default: gpt-4o)");
    Console.Error.WriteLine("  --search-connection <name>  AI Search connection name");
    Console.Error.WriteLine("  --index-name <name>         AI Search index (default: sharepoint-index)");
    Console.Error.WriteLine("  --agent-name <name>         Agent name (default: sharepoint-knowledge-agent)");
    Console.Error.WriteLine("  --test <query>              Query an existing agent");
    Console.Error.WriteLine("  --sample <name>             Query sample: direct-search | foundry-iq");
    Console.Error.WriteLine("  --query <text>              Query text for sample modes");
    Console.Error.WriteLine("  --search-endpoint <url>     AI Search endpoint for sample modes");
    Console.Error.WriteLine("  --search-key <key>          AI Search key (optional, uses Entra ID if omitted)");
    Console.Error.WriteLine("  --user-ids <ids>            ACL user IDs (comma/pipe/semicolon/space separated)");
    Console.Error.WriteLine("  --group-ids <ids>           ACL group IDs (comma/pipe/semicolon/space separated)");
    Console.Error.WriteLine("  --top <n>                   Max results for search/query samples (default: 5)");
    return 1;
}

var credential = new DefaultAzureCredential();
var client = new AIProjectClient(new Uri(endpoint), credential);

// -- Query sample mode ------------------------------------------------------
if (!string.IsNullOrEmpty(sample))
{
    if (string.IsNullOrWhiteSpace(query))
    {
        Console.Error.WriteLine("[ERROR] --query is required when using --sample");
        return 1;
    }
    if (string.IsNullOrWhiteSpace(searchEndpoint))
    {
        Console.Error.WriteLine("[ERROR] --search-endpoint is required when using --sample");
        return 1;
    }

    try
    {
        var searchClient = CreateSearchClient(searchEndpoint, indexName, searchKey, credential);
        var trimmedDocs = await QuerySearchWithAclAsync(searchClient, query, userIds, groupIds, top);

        if (sample.Equals("direct-search", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"[SAMPLE:direct-search] Query: {query}");
            Console.WriteLine($"[SAMPLE:direct-search] ACL principals: users={userIds.Count}, groups={groupIds.Count}");
            Console.WriteLine($"[SAMPLE:direct-search] Matches: {trimmedDocs.Count}");
            Console.WriteLine();

            foreach (var d in trimmedDocs)
            {
                var title = GetString(d, "title");
                var users = GetString(d, "acl_user_ids");
                var groups = GetString(d, "acl_group_ids");
                Console.WriteLine($"- {title}");
                Console.WriteLine($"  acl_user_ids={users}");
                Console.WriteLine($"  acl_group_ids={groups}");
            }

            return 0;
        }

        if (sample.Equals("foundry-iq", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"[SAMPLE:foundry-iq] Query: {query}");
            Console.WriteLine($"[SAMPLE:foundry-iq] Retrieved ACL-trimmed docs: {trimmedDocs.Count}");

            var agentRef = new AgentReference(agentName, "latest");
            var responsesClient = client.OpenAI.GetProjectResponsesClientForAgent(agentRef);

            var allowedContext = BuildAllowedDocsContext(trimmedDocs);
            var prompt =
                "You are a Foundry knowledge assistant. Answer only from the ACL-trimmed documents below. " +
                "If the answer is not in the provided documents, say that it is not available for this user context. " +
                "Always cite document titles in your answer.\n\n" +
                $"User IDs: {string.Join(",", userIds)}\n" +
                $"Group IDs: {string.Join(",", groupIds)}\n\n" +
                "ACL-trimmed documents:\n" +
                allowedContext +
                $"\nQuestion: {query}";

            var response = await responsesClient.CreateResponseAsync(prompt);
            Console.WriteLine();
            Console.WriteLine("[SAMPLE:foundry-iq] Response:");
            Console.WriteLine(response.Value.GetOutputText());
            return 0;
        }

        Console.Error.WriteLine("[ERROR] Unknown --sample value. Use: direct-search | foundry-iq");
        return 1;
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"[ERROR] Sample query failed: {ex.Message}");
        return 1;
    }
}

// -- Test mode: query an existing agent -----------------------------------
if (!string.IsNullOrEmpty(testQuery))
{
    Console.WriteLine($"[TEST] Querying agent '{agentName}' with: {testQuery}");
    try
    {
        var agentRef = new AgentReference(agentName, "latest");
        var responsesClient = client.OpenAI.GetProjectResponsesClientForAgent(agentRef);
        var response = await responsesClient.CreateResponseAsync(testQuery);
        Console.WriteLine($"[RESPONSE] {response.Value.GetOutputText()}");
        return 0;
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"[ERROR] Test failed: {ex.Message}");
        return 1;
    }
}

// -- Create mode ----------------------------------------------------------
Console.WriteLine($"[INFO] Creating agent '{agentName}' on {endpoint}");
Console.WriteLine($"[INFO] Model: {model}");

var agentDef = new PromptAgentDefinition(model)
{
    Instructions =
        "You are a helpful assistant that answers questions using the SharePoint " +
        "knowledge base. Always cite the source document name when referencing " +
        "information. If the user asks about documents or files, search the " +
        "knowledge base. Keep answers concise and accurate."
};

// Add Azure AI Search tool if connection is provided
if (!string.IsNullOrEmpty(searchConn))
{
    Console.WriteLine($"[INFO] Resolving search connection: {searchConn}");

    string connectionId = searchConn;
    try
    {
        var conn = client.Connections.GetConnection(searchConn);
        connectionId = conn.Id;
        Console.WriteLine($"[INFO] Connection resolved → ID: {connectionId}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[WARN] Could not resolve connection ({ex.Message}), using name as-is");
    }

    var searchIndex = new AzureAISearchToolIndex()
    {
        ProjectConnectionId = connectionId,
        IndexName = indexName,
        TopK = 5,
        QueryType = AzureAISearchQueryType.VectorSemanticHybrid
    };

    var searchTool = new AzureAISearchTool(new AzureAISearchToolOptions(indexes: [searchIndex]));
    agentDef.Tools.Add(searchTool);
    Console.WriteLine($"[INFO] AI Search tool added (index: {indexName}, hybrid search)");
}

// Create agent version
try
{
    var agentVersion = await client.Agents
        .CreateAgentVersionAsync(agentName, new AgentVersionCreationOptions(agentDef));

    Console.WriteLine();
    Console.WriteLine($"[OK] Agent created successfully!");
    Console.WriteLine($"  Name:    {agentVersion.Value.Name}");
    Console.WriteLine($"  Version: {agentVersion.Value.Version}");
    Console.WriteLine($"  ID:      {agentVersion.Value.Id}");
    Console.WriteLine();
    Console.WriteLine($"Test with:");
    Console.WriteLine($"  dotnet run -- --endpoint \"{endpoint}\" --test \"What documents are available?\"");
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine($"[ERROR] Agent creation failed: {ex.Message}");
    Console.Error.WriteLine(ex.ToString());
    return 1;
}
