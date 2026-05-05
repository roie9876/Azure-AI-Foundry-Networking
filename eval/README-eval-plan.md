# RAG Evaluation Plan — sharepoint-agentic Agent

## Environment
| Field | Value |
|-------|-------|
| Project | projectrzgn |
| Agent | sharepoint-agentic |
| Model | gpt-5.4 |
| Knowledge Base | sharepoint-kb |
| Subscription | f81ed7c0-efed-4b77-b948-b85407bdb710 |
| Resource Group | spoke4-foundry-deny |

---

## Phase 1: Built-in Evaluators Only (Start Here)

### Which evaluators and why

| Evaluator | Type | Why you need it | Required fields |
|-----------|------|-----------------|-----------------|
| **Groundedness** | System | Does the agent stay grounded in the IEC document? No hallucinated rules | query, response, context |
| **Relevance** | System | Does the answer actually address what the user asked? | query, response |
| **Retrieval** | Process | Did sharepoint-kb return the right chunks? | query, context |

These 3 cover the most important dimensions for a regulatory RAG agent.
**You do NOT need custom evaluators yet.**

### Recommended thresholds (first run)

| Evaluator | Pass threshold | Rationale |
|-----------|---------------|-----------|
| Groundedness | 4 (out of 5) | Regulatory content - must be highly grounded |
| Relevance | 3 (out of 5) | First baseline - tighten later |
| Retrieval | 3 (out of 5) | First baseline - tighten later |

---

## Phase 2: Portal Step-by-Step Walkthrough

### Step 1: Upload the evaluation dataset

1. Open **Microsoft Foundry Portal** → navigate to project **projectrzgn**
2. Click **Evaluations** in the left sidebar
3. Click **"Create"** (top right)
4. In the wizard, choose **"Agent"** as the target type
5. Select agent: **sharepoint-agentic**
6. For data source, choose **"Upload file"**
7. Upload the file: `eval/iec-eval-dataset.jsonl`

### Step 2: Configure data mappings

Map the dataset fields to what evaluators expect:

| Evaluator field | Maps to |
|----------------|---------|
| `query` | `{{item.query}}` |
| `response` | `{{sample.output_items}}` (agent generates this) |
| `context` | auto-extracted from tool call results (since the agent uses `knowledge_base_retrieve`) |

> **Important**: Because your agent uses the `knowledge_base_retrieve` tool, context is automatically extracted from the tool call results. You do NOT need a `context` field in your dataset.

### Step 3: Select evaluators (Criteria step)

1. Click **"Add evaluator"**
2. Select **Groundedness** from the built-in catalog
   - Set deployment: your judge model (e.g., gpt-5.4 or another deployment)
   - Set threshold: **4**
3. Click **"Add evaluator"** again
4. Select **Relevance**
   - Set deployment: same judge model
   - Set threshold: **3**
5. Click **"Add evaluator"** again
6. Select **Retrieval**
   - Set deployment: same judge model
   - Set threshold: **3**

### Step 4: Run the evaluation

1. Give it a name, e.g.: `iec-eval-baseline-v1`
2. Click **"Submit"**
3. Wait for completion (monitor in the Evaluations list)

### Step 5: Analyze results

After the run completes:
1. Click on the run name to see per-row scores
2. Look at:
   - **Overall pass rate** per evaluator
   - **Failed rows** — click to see the reason for each failure
   - **Low-scoring retrieval rows** — these mean sharepoint-kb didn't find the right chunks
3. Sort by score ascending to find the worst answers first

---

## Phase 3: When to Add Custom Evaluators

Add custom evaluators ONLY if built-in evaluators miss your business requirements.

**Examples of when you'd need custom:**
- Agent must always cite the specific אמת מידה number → custom evaluator checking for citation pattern
- Agent must answer in Hebrew only → custom code-based evaluator checking language
- Agent must not provide legal advice → custom prompt-based evaluator for tone/scope

**Do NOT add custom evaluators before running Phase 1.** The first run tells you what's actually failing.

---

## Phase 4: Continuous Evaluation (After Baseline)

### Option A: Manual scheduled runs (simplest)
1. In Foundry Portal → Evaluations → click the 3-dot menu on your eval
2. Click **"Clone"** to reuse same config
3. Run weekly or after any agent instruction changes

### Option B: SDK automation (recommended for production)
```python
# Run eval programmatically — schedule via Azure Functions / Logic Apps / cron
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient

endpoint = "https://<account>.services.ai.azure.com/api/projects/projectrzgn"
client = AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential())
oai = client.get_openai_client()

eval_obj = oai.evals.create(
    name="iec-eval-nightly",
    data_source_config={...},
    testing_criteria=[
        {"type": "azure_ai_evaluator", "evaluator_name": "builtin.groundedness", ...},
        {"type": "azure_ai_evaluator", "evaluator_name": "builtin.relevance", ...},
        {"type": "azure_ai_evaluator", "evaluator_name": "builtin.retrieval", ...},
    ]
)
# Then create a run and poll for results
```

### Regression gates (for CI/CD)
| Metric | Hard gate | Soft gate |
|--------|-----------|-----------|
| Groundedness pass rate | ≥ 85% | Alert if drops > 5% from last run |
| Relevance pass rate | ≥ 70% | Alert if drops > 10% from last run |
| Retrieval pass rate | ≥ 70% | Alert if drops > 10% from last run |

---

## Dataset file location
- **JSONL file**: `eval/iec-eval-dataset.jsonl`
- **30 questions** covering: definitions, tariffs, billing, disconnection, compensation, renewables, confidentiality, connections, grid operations
- **Language**: Hebrew (matching the source document)
- **Format**: `query` + `expected_behavior` (behavioral rubric, not exact answer)

## Next steps after first run
1. Review failures → identify if retrieval or generation is the bottleneck
2. If retrieval is poor → tune search index parameters (chunk size, overlap, semantic vs hybrid)
3. If generation is poor → improve agent instructions
4. After improvements → re-run eval and compare with baseline
5. When stable → set up nightly/weekly schedule
