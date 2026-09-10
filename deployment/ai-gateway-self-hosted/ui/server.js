const { useAzureMonitor } = require("@azure/monitor-opentelemetry");
const { SpanKind, SpanStatusCode, trace } = require("@opentelemetry/api");

if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  useAzureMonitor({
    samplingRatio: 1,
    tracesPerSecond: 0,
    enableLiveMetrics: false,
    instrumentationOptions: {
      http: {
        requestHook: (span, request) => {
          const identity = getIdentity(request);
          if (identity) {
            span.setAttributes({
              "enduser.id": identity.id || identity.account || "unknown",
              "enduser.pseudo.id": identity.account || identity.name || "unknown",
              "app.user.object_id": identity.id || "unknown",
              "app.user.name": identity.name || "unknown",
              "app.user.account": identity.account || "unknown",
              "app.policy.tier": identity.tier,
            });
          }
        },
      },
    },
  });
}

const http = require("node:http");
const https = require("node:https");
const fs = require("node:fs");
const path = require("node:path");
const { randomUUID } = require("node:crypto");

const tracer = trace.getTracer("ai-gateway-external-app");

const port = Number(process.env.PORT || 3000);
const gatewayUrl = process.env.GATEWAY_URL || "http://localhost:8080";
const gatewayHost = process.env.GATEWAY_HOST || "apim-aigw-shgw-demo1234.azure-api.net";
const apiPath = process.env.API_PATH || "aif-aigw-shgw-demo1234";
const model = process.env.MODEL || "gpt-4.1-mini";
const apiKey = process.env.API_KEY || "";
const agentId = process.env.OTEL_AGENT_ID || "ai-gateway-external-agent";
const indexHtml = fs.readFileSync(path.join(__dirname, "public", "index.html"));

function sendJson(response, status, body) {
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(JSON.stringify(body));
}

function extractText(payload) {
  if (typeof payload.output_text === "string") return payload.output_text;
  for (const item of payload.output || []) {
    for (const content of item.content || []) {
      if (typeof content.text === "string") return content.text;
    }
  }
  return "The model completed without a text response.";
}

function getIdentity(request) {
  const encodedPrincipal = request.headers["x-ms-client-principal"];
  if (!encodedPrincipal) return null;

  try {
    const principal = JSON.parse(Buffer.from(encodedPrincipal, "base64").toString("utf8"));
    const claims = principal.claims || principal.user_claims || [];
    const claimValue = (...types) => claims.find((claim) => types.some(
      (type) => claim.typ === type || claim.typ.endsWith(`/${type}`),
    ))?.val;
    const roles = claims
      .filter((claim) => claim.typ === "roles" || claim.typ.endsWith("/role"))
      .map((claim) => claim.val);
    return {
      id: principal.userId || principal.user_id || claimValue("oid", "objectidentifier"),
      name: request.headers["x-ms-client-principal-name"] || principal.userDetails,
      account: claimValue("preferred_username", "upn", "email") || principal.userDetails,
      roles,
      tier: roles.includes("AI.Limited") ? "Limited" : "Unlimited",
    };
  } catch {
    return null;
  }
}

function callGateway(targetUrl, method, headers, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(targetUrl);
    const transport = target.protocol === "https:" ? https : http;
    const gatewayRequest = transport.request(target, { method, headers, timeout: 60_000 }, (gatewayResponse) => {
      const chunks = [];
      gatewayResponse.on("data", (chunk) => chunks.push(chunk));
      gatewayResponse.on("end", () => {
        resolve({
          status: gatewayResponse.statusCode || 502,
          contentType: gatewayResponse.headers["content-type"] || "application/json",
          body: Buffer.concat(chunks),
        });
      });
    });
    gatewayRequest.on("timeout", () => gatewayRequest.destroy(new Error("Gateway request timed out.")));
    gatewayRequest.on("error", reject);
    if (body?.length) gatewayRequest.write(body);
    gatewayRequest.end();
  });
}

async function runModel(request, response) {
  if (!apiKey) {
    sendJson(response, 503, { error: "The demo API key is not configured." });
    return;
  }

  const identityToken = request.headers["x-ms-token-aad-id-token"];
  if (!identityToken) {
    sendJson(response, 401, { error: "Microsoft Entra authentication is required." });
    return;
  }

  let body = "";
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 16_384) {
      sendJson(response, 413, { error: "Request is too large." });
      return;
    }
  }

  let prompt = "Share one practical benefit of an AI gateway in one sentence.";
  let conversationId = randomUUID();
  try {
    const parsed = body ? JSON.parse(body) : {};
    if (typeof parsed.prompt === "string" && parsed.prompt.trim()) {
      prompt = parsed.prompt.trim().slice(0, 1_000);
    }
    if (typeof parsed.conversationId === "string" && /^[a-zA-Z0-9_-]{1,64}$/.test(parsed.conversationId)) {
      conversationId = parsed.conversationId;
    }
  } catch {
    sendJson(response, 400, { error: "Invalid JSON request." });
    return;
  }

  const identity = getIdentity(request);
  await tracer.startActiveSpan(`invoke_agent ${agentId}`, { kind: SpanKind.INTERNAL }, async (span) => {
    span.setAttributes({
      "gen_ai.operation.name": "invoke_agent",
      "gen_ai.system": "openai",
      "gen_ai.agent.id": agentId,
      "gen_ai.agent.name": agentId,
      "microsoft.gen_ai.main_agent.id": agentId,
      "microsoft.gen_ai.main_agent.name": agentId,
      "microsoft.gen_ai.main_agent.conversation_id": conversationId,
      "gen_ai.request.model": model,
      "gen_ai.conversation.id": conversationId,
      "gen_ai.input.messages": JSON.stringify([{ role: "user", parts: [{ type: "text", content: prompt }] }]),
      "enduser.id": identity?.id || identity?.account || "unknown",
      "enduser.pseudo.id": identity?.account || identity?.name || "unknown",
      "app.user.object_id": identity?.id || "unknown",
      "app.user.name": identity?.name || "unknown",
      "app.user.account": identity?.account || "unknown",
      "app.policy.tier": identity?.tier || "unknown",
      "app.policy.roles": identity?.roles?.join(",") || "",
      "server.address": gatewayHost,
    });

    try {
      const requestBody = Buffer.from(JSON.stringify({ model, input: prompt, max_output_tokens: 160 }));
      const gatewayResponse = await callGateway(
        `${gatewayUrl}/${apiPath.replace(/^\/+|\/+$/g, "")}/openai/v1/responses`,
        "POST",
        {
          "Content-Type": "application/json",
          "Content-Length": requestBody.length,
          "Authorization": `Bearer ${identityToken}`,
          "api-key": apiKey,
          "Host": gatewayHost,
          "X-Forwarded-Proto": "https",
        },
        requestBody,
      );
      const payload = JSON.parse(gatewayResponse.body.toString("utf8"));
      span.setAttribute("http.response.status_code", gatewayResponse.status);

      if (gatewayResponse.status < 200 || gatewayResponse.status >= 300) {
        const errorMessage = payload.message || payload.error?.message || "Gateway request failed.";
        const policyOutcome = gatewayResponse.status === 429
          ? "token_limit"
          : gatewayResponse.status === 403
            ? "content_safety"
            : "gateway_error";
        span.setAttributes({
          "app.policy.outcome": policyOutcome,
          "error.type": `HTTP ${gatewayResponse.status}`,
          "gen_ai.output.messages": JSON.stringify([{ role: "assistant", parts: [{ type: "text", content: errorMessage }] }]),
        });
        span.setStatus({ code: SpanStatusCode.ERROR, message: errorMessage });
        sendJson(response, gatewayResponse.status, { error: errorMessage, conversationId });
        return;
      }

      const output = extractText(payload);
      span.setAttributes({
        "app.policy.outcome": "allowed",
        "gen_ai.response.id": payload.id || "",
        "gen_ai.response.model": payload.model || model,
        "gen_ai.output.messages": JSON.stringify([{ role: "assistant", parts: [{ type: "text", content: output }] }]),
      });
      if (Number.isFinite(payload.usage?.input_tokens)) {
        span.setAttribute("gen_ai.usage.input_tokens", payload.usage.input_tokens);
      }
      if (Number.isFinite(payload.usage?.output_tokens)) {
        span.setAttribute("gen_ai.usage.output_tokens", payload.usage.output_tokens);
      }
      span.setStatus({ code: SpanStatusCode.OK });
      sendJson(response, 200, { text: output, model, conversationId });
    } catch (error) {
      span.recordException(error);
      span.setAttributes({
        "app.policy.outcome": "gateway_unavailable",
        "error.type": error.name || "Error",
      });
      span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
      sendJson(response, 502, { error: `Gateway unavailable: ${error.message}`, conversationId });
    } finally {
      span.end();
    }
  });
}

async function proxyGateway(request, response) {
  const identityToken = request.headers["x-ms-token-aad-id-token"];
  if (!identityToken) {
    sendJson(response, 401, { error: "Microsoft Entra authentication is required." });
    return;
  }

  let body = Buffer.alloc(0);
  for await (const chunk of request) {
    body = Buffer.concat([body, chunk]);
    if (body.length > 1_048_576) {
      sendJson(response, 413, { error: "Request is too large." });
      return;
    }
  }

  try {
    const gatewayResponse = await callGateway(
      `${gatewayUrl}${request.url}`,
      request.method,
      {
        "Content-Type": request.headers["content-type"] || "application/json",
        "Content-Length": body.length,
        "Authorization": `Bearer ${identityToken}`,
        "api-key": request.headers["api-key"] || apiKey,
        "Host": gatewayHost,
        "X-Forwarded-Proto": "https",
      },
      request.method === "GET" || request.method === "HEAD" ? null : body,
    );
    response.writeHead(gatewayResponse.status, {
      "Content-Type": gatewayResponse.contentType,
      "Cache-Control": "no-store",
    });
    response.end(gatewayResponse.body);
  } catch (error) {
    sendJson(response, 502, { error: `Gateway unavailable: ${error.message}` });
  }
}

const server = http.createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/") {
    response.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
    });
    response.end(indexHtml);
    return;
  }
  if (request.method === "GET" && request.url === "/healthz") {
    sendJson(response, 200, { status: "ok" });
    return;
  }
  if (request.method === "GET" && request.url === "/api/me") {
    const identity = getIdentity(request);
    if (!identity) {
      sendJson(response, 401, { error: "Microsoft Entra authentication is required." });
      return;
    }
    sendJson(response, 200, identity);
    return;
  }
  if (request.method === "POST" && request.url === "/api/run") {
    await runModel(request, response);
    return;
  }
  if (
    request.url === "/status-0123456789abcdef" ||
    request.url.startsWith(`/${apiPath.replace(/^\/+|\/+$/g, "")}/`)
  ) {
    await proxyGateway(request, response);
    return;
  }
  sendJson(response, 404, { error: "Not found." });
});

server.listen(port, "0.0.0.0", () => {
  console.log(`Demo UI listening on port ${port}`);
});