using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using SharePointSyncFunc.Configuration;
using SharePointSyncFunc.Services;

var builder = FunctionsApplication.CreateBuilder(args);

// Forward worker-side ILogger output through the Functions host's Application
// Insights pipeline. The host reads APPLICATIONINSIGHTS_CONNECTION_STRING and does
// the actual ingestion — no separate AI SDK package is needed here. The legacy
// Microsoft.ApplicationInsights.WorkerService SDK was deprecated, so we don't
// pull it in.
builder.Services.ConfigureFunctionsApplicationInsights();

builder.Services.AddSingleton<SyncConfig>(_ => SyncConfig.FromEnvironment());
builder.Services.AddTransient<SyncOrchestrator>();
builder.Services.AddHttpClient();

builder.Services.AddLogging(logging =>
{
    logging.AddSimpleConsole(options =>
    {
        options.IncludeScopes = true;
        options.SingleLine = true;
        options.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ ";
    });
});

builder.Build().Run();
