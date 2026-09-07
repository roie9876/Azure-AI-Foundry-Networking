const http = require("node:http");
const https = require("node:https");
const fs = require("node:fs");
const path = require("node:path");

const port = Number(process.env.PORT || 3000);
const gatewayUrl = process.env.GATEWAY_URL || "http://localhost:8080";
const gatewayHost = process.env.GATEWAY_HOST || "apim-aigw-shgw-demo1234.azure-api.net";
const apiPath = process.env.API_PATH || "aif-aigw-shgw-demo1234";
const model = process.env.MODEL || "gpt-4.1-mini";
const apiKey = process.env.API_KEY || "";
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

  let body = "";
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 16_384) {
      sendJson(response, 413, { error: "Request is too large." });
      return;
    }
  }

  let prompt = "Share one practical benefit of an AI gateway in one sentence.";
  try {
    const parsed = body ? JSON.parse(body) : {};
    if (typeof parsed.prompt === "string" && parsed.prompt.trim()) {
      prompt = parsed.prompt.trim().slice(0, 1_000);
    }
  } catch {
    sendJson(response, 400, { error: "Invalid JSON request." });
    return;
  }

  try {
    const requestBody = Buffer.from(JSON.stringify({ model, input: prompt, max_output_tokens: 160 }));
    const gatewayResponse = await callGateway(
      `${gatewayUrl}/${apiPath.replace(/^\/+|\/+$/g, "")}/openai/v1/responses`,
      "POST",
      {
        "Content-Type": "application/json",
        "Content-Length": requestBody.length,
        "api-key": apiKey,
        "Host": gatewayHost,
        "X-Forwarded-Proto": "https",
      },
      requestBody,
    );
    const payload = JSON.parse(gatewayResponse.body.toString("utf8"));
    if (gatewayResponse.status < 200 || gatewayResponse.status >= 300) {
      sendJson(response, gatewayResponse.status, {
        error: payload.message || payload.error?.message || "Gateway request failed.",
      });
      return;
    }
    sendJson(response, 200, { text: extractText(payload), model });
  } catch (error) {
    sendJson(response, 502, { error: `Gateway unavailable: ${error.message}` });
  }
}

async function proxyGateway(request, response) {
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