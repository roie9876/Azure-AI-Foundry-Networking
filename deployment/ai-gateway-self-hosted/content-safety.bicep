@description('Name of the existing API Management service.')
param apimName string

@description('Foundry-generated APIM product that contains the model API.')
param foundryProductId string

@description('Internal endpoint of the customer-hosted Content Safety container.')
param contentSafetyEndpoint string

@description('Block Hate at this severity or higher.')
@minValue(1)
@maxValue(7)
param hateThreshold int = 1

@description('Block Violence at this severity or higher.')
@minValue(1)
@maxValue(7)
param violenceThreshold int = 1

@description('Block Sexual content at this severity or higher.')
@minValue(1)
@maxValue(7)
param sexualThreshold int = 1

@description('Block Self-harm at this severity or higher.')
@minValue(1)
@maxValue(7)
param selfHarmThreshold int = 1

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource foundryProduct 'Microsoft.ApiManagement/service/products@2024-05-01' existing = {
  parent: apim
  name: foundryProductId
}

resource contentSafetyPolicy 'Microsoft.ApiManagement/service/products/policies@2024-05-01' = {
  parent: foundryProduct
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(replace(replace(replace(replace('''
      <policies>
        <inbound>
          <base />
          <set-variable name="contentSafetyText" value="@{
            var body = context.Request.Body.As&lt;JObject&gt;(preserveContent: true);
            var input = body[&quot;input&quot;];
            if (input == null) { return string.Empty; }
            if (input.Type == JTokenType.String) { return (string)input; }
            return input.ToString(Newtonsoft.Json.Formatting.None);
          }" />
          <choose>
            <when condition="@(!string.IsNullOrWhiteSpace((string)context.Variables[&quot;contentSafetyText&quot;]))">
              <send-request mode="new" response-variable-name="contentSafetyResponse" timeout="30" ignore-error="false">
                <set-url>__CONTENT_SAFETY_ENDPOINT__/contentsafety/text:analyze?api-version=2024-09-01</set-url>
                <set-method>POST</set-method>
                <set-header name="Content-Type" exists-action="override">
                  <value>application/json</value>
                </set-header>
                <set-body>@{
                  return new JObject(
                    new JProperty(&quot;text&quot;, (string)context.Variables[&quot;contentSafetyText&quot;]),
                    new JProperty(&quot;outputType&quot;, &quot;FourSeverityLevels&quot;)
                  ).ToString();
                }</set-body>
              </send-request>
              <set-variable name="contentSafetyBlockReason" value="@{
                var response = (IResponse)context.Variables[&quot;contentSafetyResponse&quot;];
                if (response.StatusCode != 200) { return &quot;Content Safety service unavailable&quot;; }
                var result = response.Body.As&lt;JObject&gt;();
                var categories = result[&quot;categoriesAnalysis&quot;] as JArray;
                if (categories == null) { return &quot;Invalid Content Safety response&quot;; }
                foreach (var category in categories)
                {
                  var categoryName = (string)category[&quot;category&quot;];
                  var severity = (int?)category[&quot;severity&quot;] ?? 0;
                  var threshold =
                    categoryName.Equals(&quot;hate&quot;, StringComparison.OrdinalIgnoreCase) ? __HATE_THRESHOLD__ :
                    categoryName.Equals(&quot;violence&quot;, StringComparison.OrdinalIgnoreCase) ? __VIOLENCE_THRESHOLD__ :
                    categoryName.Equals(&quot;sexual&quot;, StringComparison.OrdinalIgnoreCase) ? __SEXUAL_THRESHOLD__ :
                    categoryName.Equals(&quot;selfHarm&quot;, StringComparison.OrdinalIgnoreCase) ? __SELF_HARM_THRESHOLD__ :
                    7;
                  if (severity &gt;= threshold)
                  {
                    return string.Format(&quot;{0} severity {1}&quot;, categoryName, severity);
                  }
                }
                return string.Empty;
              }" />
              <choose>
                <when condition="@(!string.IsNullOrEmpty((string)context.Variables[&quot;contentSafetyBlockReason&quot;]))">
                  <return-response>
                    <set-status code="403" reason="Content Safety blocked the prompt" />
                    <set-header name="Content-Type" exists-action="override">
                      <value>application/json</value>
                    </set-header>
                    <set-body>@{
                      return new JObject(
                        new JProperty(&quot;error&quot;, new JObject(
                          new JProperty(&quot;code&quot;, &quot;ContentSafetyViolation&quot;),
                          new JProperty(&quot;message&quot;, &quot;Prompt blocked by Azure AI Content Safety.&quot;),
                          new JProperty(&quot;reason&quot;, (string)context.Variables[&quot;contentSafetyBlockReason&quot;])
                        ))
                      ).ToString();
                    }</set-body>
                  </return-response>
                </when>
              </choose>
            </when>
          </choose>
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
    ''', '__CONTENT_SAFETY_ENDPOINT__', contentSafetyEndpoint), '__HATE_THRESHOLD__', string(hateThreshold)), '__VIOLENCE_THRESHOLD__', string(violenceThreshold)), '__SEXUAL_THRESHOLD__', string(sexualThreshold)), '__SELF_HARM_THRESHOLD__', string(selfHarmThreshold))
  }
}