const assert = require("node:assert/strict");
const test = require("node:test");

const { extractCodexQuestion, extractCodexResponse } = require("./server");

test("extracts the last user question from a Responses request", () => {
  const body = Buffer.from(JSON.stringify({
    input: [
      { role: "user", content: [{ type: "input_text", text: "Earlier context" }] },
      { role: "assistant", content: [{ type: "output_text", text: "Earlier answer" }] },
      { role: "user", content: [{ type: "input_text", text: "What is the current status?" }] },
    ],
  }));

  assert.equal(extractCodexQuestion(body), "What is the current status?");
});

test("extracts answer and usage from a Responses SSE completion", () => {
  const response = {
    id: "resp_test",
    output: [{ content: [{ type: "output_text", text: "The gateway is healthy." }] }],
    usage: { input_tokens: 120, output_tokens: 8, total_tokens: 128 },
  };
  const body = Buffer.from([
    "event: response.output_text.done",
    'data: {"type":"response.output_text.done","text":"The gateway is healthy."}',
    "",
    "event: response.completed",
    `data: ${JSON.stringify({ type: "response.completed", response })}`,
    "",
    "data: [DONE]",
  ].join("\n"));

  const result = extractCodexResponse(body, "text/event-stream; charset=utf-8");

  assert.equal(result.answer, "The gateway is healthy.");
  assert.deepEqual(result.response.usage, response.usage);
});