@description('Name of the existing API Management service.')
param apimName string

@description('Name of the existing Foundry backend in API Management.')
param foundryBackendId string

@description('Foundry project name used by the Responses API.')
param foundryProjectName string

@description('Microsoft Entra tenant that issues Codex user tokens.')
param entraTenantId string

@description('Application client ID expected in the token audience.')
param entraAudience string

@description('Model deployment that Codex CLI must use.')
param modelDeploymentName string = 'gpt-5.1-codex'

@description('Maximum estimated prompt and completion tokens per Entra user per minute.')
@minValue(1000)
param tokensPerMinute int = 500000

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource codexApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'codex-cli-foundry'
  properties: {
    displayName: 'Codex CLI through self-hosted AI Gateway'
    description: 'Entra-authenticated OpenAI Responses API for Codex CLI.'
    path: 'codex'
    protocols: [
      'http'
      'https'
    ]
    subscriptionRequired: false
  }
}

resource responsesOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: codexApi
  name: 'responses'
  properties: {
    displayName: 'Create response'
    method: 'POST'
    urlTemplate: '/openai/v1/responses'
    templateParameters: []
    responses: []
  }
}

resource codexPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: codexApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: replace(replace(replace(replace(replace(replace('''
      <policies>
        <inbound>
          <validate-azure-ad-token tenant-id="__TENANT_ID__" output-token-variable-name="userJwt" failed-validation-httpcode="401" failed-validation-error-message="Microsoft Entra authentication is required.">
            <audiences>
              <audience>__AUDIENCE__</audience>
            </audiences>
            <required-claims>
              <claim name="scp" match="any">
                <value>AiGateway.Invoke</value>
              </claim>
              <claim name="roles" match="any">
                <value>Gateway.Invoke</value>
              </claim>
            </required-claims>
          </validate-azure-ad-token>
          <set-backend-service backend-id="__BACKEND_ID__" />
          <rewrite-uri template="/api/projects/__PROJECT_NAME__/openai/v1/responses" />
          <set-body>@{
            var body = context.Request.Body.As&lt;JObject&gt;(preserveContent: true);
            body[&quot;model&quot;] = &quot;__MODEL_NAME__&quot;;
            return body.ToString(Newtonsoft.Json.Formatting.None);
          }</set-body>
          <llm-token-limit counter-key="@(((Jwt)context.Variables[&quot;userJwt&quot;]).Claims[&quot;oid&quot;].First())" tokens-per-minute="__TOKENS_PER_MINUTE__" estimate-prompt-tokens="true" />
        </inbound>
        <backend>
          <base />
        </backend>
        <outbound>
          <base />
        </outbound>
        <on-error>
          <base />
        </on-error>
      </policies>
    ''', '__TENANT_ID__', entraTenantId), '__AUDIENCE__', entraAudience), '__BACKEND_ID__', foundryBackendId), '__PROJECT_NAME__', foundryProjectName), '__MODEL_NAME__', modelDeploymentName), '__TOKENS_PER_MINUTE__', string(tokensPerMinute))
  }
  dependsOn: [
    responsesOperation
  ]
}

output apiId string = codexApi.name
output apiPath string = codexApi.properties.path