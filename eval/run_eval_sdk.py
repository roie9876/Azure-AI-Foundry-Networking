"""
Run agent-targeted evaluation via SDK for the IEC agent.
Uses inline data (no blob storage upload required).

Usage:
  export AZURE_AI_PROJECT_ENDPOINT="https://<account>.services.ai.azure.com/api/projects/<project>"
  export AZURE_AI_MODEL_DEPLOYMENT_NAME="gpt-4.1"   # judge model
  python eval/run_eval_sdk.py

Docs: https://learn.microsoft.com/en-us/azure/foundry/observability/how-to/evaluate-agent
"""
import os
import time
import json
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient

# --- Config ---
endpoint = os.environ["AZURE_AI_PROJECT_ENDPOINT"]
model_deployment = os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "gpt-4.1")
agent_name = "iec"
dataset_path = os.path.join(os.path.dirname(__file__), "iec-eval-dataset.jsonl")

# --- Setup ---
credential = DefaultAzureCredential()
project_client = AIProjectClient(endpoint=endpoint, credential=credential)
client = project_client.get_openai_client()

# --- Step 1: Load dataset as inline data ---
print("Loading dataset...")
with open(dataset_path) as f:
    rows = [json.loads(line) for line in f if line.strip()]
print(f"Loaded {len(rows)} test cases")

# --- Step 2: Define evaluators ---
testing_criteria = [
    # Agent evaluators
    {
        "type": "azure_ai_evaluator",
        "name": "ToolOutputUtilization",
        "evaluator_name": "builtin.tool_output_utilization",
        "data_mapping": {
            "query": "{{item.query}}",
            "response": "{{sample.output_items}}",
        },
        "initialization_parameters": {"deployment_name": model_deployment},
    },
    {
        "type": "azure_ai_evaluator",
        "name": "TaskCompletion",
        "evaluator_name": "builtin.task_completion",
        "data_mapping": {
            "query": "{{item.query}}",
            "response": "{{sample.output_items}}",
        },
        "initialization_parameters": {"deployment_name": model_deployment},
    },
    {
        "type": "azure_ai_evaluator",
        "name": "TaskAdherence",
        "evaluator_name": "builtin.task_adherence",
        "data_mapping": {
            "query": "{{item.query}}",
            "response": "{{sample.output_items}}",
        },
        "initialization_parameters": {"deployment_name": model_deployment},
    },
    {
        "type": "azure_ai_evaluator",
        "name": "IntentResolution",
        "evaluator_name": "builtin.intent_resolution",
        "data_mapping": {
            "query": "{{item.query}}",
            "response": "{{sample.output_items}}",
        },
        "initialization_parameters": {"deployment_name": model_deployment},
    },
    # Quality evaluators
    {
        "type": "azure_ai_evaluator",
        "name": "Groundedness",
        "evaluator_name": "builtin.groundedness",
        "data_mapping": {
            "query": "{{item.query}}",
            "response": "{{sample.output_items}}",
        },
        "initialization_parameters": {"deployment_name": model_deployment},
    },
    {
        "type": "azure_ai_evaluator",
        "name": "Relevance",
        "evaluator_name": "builtin.relevance",
        "data_mapping": {
            "query": "{{item.query}}",
            "response": "{{sample.output_text}}",
        },
        "initialization_parameters": {"deployment_name": model_deployment},
    },
    {
        "type": "azure_ai_evaluator",
        "name": "Fluency",
        "evaluator_name": "builtin.fluency",
        "data_mapping": {
            "query": "{{item.query}}",
            "response": "{{sample.output_text}}",
        },
        "initialization_parameters": {"deployment_name": model_deployment},
    },
    {
        "type": "azure_ai_evaluator",
        "name": "Coherence",
        "evaluator_name": "builtin.coherence",
        "data_mapping": {
            "query": "{{item.query}}",
            "response": "{{sample.output_text}}",
        },
        "initialization_parameters": {"deployment_name": model_deployment},
    },
]

# --- Step 3: Create evaluation ---
print("Creating evaluation...")
data_source_config = {
    "type": "custom",
    "item_schema": {
        "type": "object",
        "properties": {
            "query": {"type": "string"},
            "expected_behavior": {"type": "string"},
        },
        "required": ["query"],
    },
    "include_sample_schema": True,
}

evaluation = client.evals.create(
    name="iec-eval-sdk",
    data_source_config=data_source_config,
    testing_criteria=testing_criteria,
)
print(f"Evaluation created: {evaluation.id}")

# --- Step 4: Run evaluation with inline data against agent ---
print(f"Running eval against agent '{agent_name}' with {len(rows)} inline rows...")
inline_content = [{"item": row} for row in rows]

eval_run = client.evals.runs.create(
    eval_id=evaluation.id,
    name="iec-eval-run-sdk",
    data_source={
        "type": "azure_ai_target_completions",
        "source": {
            "type": "file_content",
            "content": inline_content,
        },
        "input_messages": {
            "type": "template",
            "template": [
                {
                    "type": "message",
                    "role": "user",
                    "content": {"type": "input_text", "text": "{{item.query}}"},
                }
            ],
        },
        "target": {
            "type": "azure_ai_agent",
            "name": agent_name,
        },
    },
)
print(f"Eval run started: {eval_run.id}")

# --- Step 5: Poll for completion ---
print("Waiting for completion...")
while True:
    run = client.evals.runs.retrieve(run_id=eval_run.id, eval_id=evaluation.id)
    print(f"  Status: {run.status}")
    if run.status in ["completed", "failed"]:
        break
    time.sleep(10)

print(f"\nFinal status: {run.status}")
print(f"Report URL: {run.report_url}")

# --- Step 6: Print summary ---
if run.status == "completed":
    output_items = list(
        client.evals.runs.output_items.list(run_id=run.id, eval_id=evaluation.id)
    )
    
    # Count pass/fail per evaluator
    evaluator_stats = {}
    for item in output_items:
        for result in item.results:
            name = result.name
            if name not in evaluator_stats:
                evaluator_stats[name] = {"pass": 0, "fail": 0, "error": 0}
            if result.passed is True:
                evaluator_stats[name]["pass"] += 1
            elif result.passed is False:
                evaluator_stats[name]["fail"] += 1
            else:
                evaluator_stats[name]["error"] += 1
    
    print("\n=== Results Summary ===")
    for name, stats in evaluator_stats.items():
        total = stats["pass"] + stats["fail"] + stats["error"]
        pass_rate = (stats["pass"] / total * 100) if total > 0 else 0
        print(f"  {name}: {pass_rate:.0f}% pass ({stats['pass']}/{total}), errors: {stats['error']}")
