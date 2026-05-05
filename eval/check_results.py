"""Check eval run results and errors."""
import os, json
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient

endpoint = os.environ["AZURE_AI_PROJECT_ENDPOINT"]
client = AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential())
oai = client.get_openai_client()

eval_id = "eval_b1763acfaf274e5cb3fa4ad4e541993d"
run_id = "evalrun_1a0d7a1e403d4a66af4c7c2e5a55f307"

# Get run details
run = oai.evals.runs.retrieve(run_id=run_id, eval_id=eval_id)
print(f"Status: {run.status}")
print(f"Error: {run.error}" if hasattr(run, 'error') and run.error else "No run-level error")

# Get output items
items = list(oai.evals.runs.output_items.list(run_id=run_id, eval_id=eval_id))
print(f"\nTotal output items: {len(items)}")

for i, item in enumerate(items[:5]):  # First 5 items
    ds = item.datasource_item
    print(f"\n{'='*60}")
    print(f"Question {i}: {ds.get('query', '')[:100]}")
    output_text = ds.get('sample.output_text', '')
    print(f"Agent response: {output_text[:300] if output_text else '(EMPTY - MCP approval blocked)'}")
    
    # Show tool calls if any
    tool_calls = ds.get('sample.tool_calls', [])
    if tool_calls:
        print(f"Tool calls: {len(tool_calls)} call(s)")
    
    sample_err = getattr(item.sample, 'error', None) if hasattr(item, 'sample') else None
    if sample_err:
        print(f"Sample error: {sample_err}")
    
    print("Evaluator scores:")
    for r in item.results:
        err_info = ""
        r_sample = getattr(r, 'sample', None)
        if r_sample:
            r_err = getattr(r_sample, 'error', None)
            if r_err:
                err_msg = getattr(r_err, 'message', str(r_err))[:80] if r_err else ''
                err_info = f" | ERROR: {err_msg}"
        reason_txt = str(r.reason)[:120] if r.reason else 'N/A'
        print(f"  {r.name:25s} score={str(r.score):5s} passed={str(r.passed):5s} | {reason_txt}{err_info}")
