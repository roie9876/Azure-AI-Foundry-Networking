# Multi-stage Dockerfile for Azure Functions .NET 10 isolated worker.
# Builds the project with the .NET SDK, then publishes into the official
# Azure Functions runtime image.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY SharePointSyncFunc.csproj ./
RUN dotnet restore SharePointSyncFunc.csproj

COPY . .
RUN dotnet publish SharePointSyncFunc.csproj -c Release -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated10.0
ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true

COPY --from=build /app/publish /home/site/wwwroot
