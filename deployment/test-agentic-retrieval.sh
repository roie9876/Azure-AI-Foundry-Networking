#!/usr/bin/env bash
###############################################################################
# test-agentic-retrieval.sh
#
# Stand-alone prototype: create AI Search Knowledge Source + Knowledge Base
# on top of the existing `sharepoint-index`, wire a second Foundry agent
# that calls it via MCP, and run a smoke test.
#
# Safe: does NOT modify deployment/3-deploy-sharepoint-sync.sh, does NOT
# touch the existing `sharepoint-remote-via-fw` agent. Creates a parallel
# agent named `sharepoint-agentic` so you can A/B compare in the Playground.
#
# Idempotent: re-run to update.
# Cleanup: set CLEANUP=1 to delete KS + KB + agent.
###############################################################################
set -euo pipefail

# shellcheck disable=SC1091
set -a; . "$(dirname "$0")/sharepoint-sync.env"; set +a

: "${SEARCH_SERVICE_NAME:?must be set}"
: "${SPOKE_RG:?must be set}"
: "${AI_SERVICES_NAME:?must be set}"
: "${FOUNDRY_PROJECT_NAME:?must be set}"
: "${SUBSCRIPTION_ID:?must be set}"

IDX="${INDEX_NAME:-sharepoint-index}"
KS_NAME="${AGENTIC_KS_NAME:-sharepoint-ks}"
KB_NAME="${AGENTIC_KB_NAME:-sharepoint-kb}"
KB_AGENT_NAME="${AGENTIC_AGENT_NAME:-sharepoint-agentic}"
PLANNER_MODEL="${AGENTIC_PLANNER_MODEL:-gpt-4.1}"
REASONING_EFFORT="${AGENTIC_REASONING_EFFORT:-low}"        # minimal | low | medium
OUTPUT_MODE="${AGENTIC_OUTPUT_MODE:-extractiveData}"        # extractiveData | answerSynthesis
PROJECT_CONN_NAME="${AGENTIC_PROJECT_CONN_NAME:-sharepoint-kb-mcp}"

SEARCH_ENDPOINT="https://${SEARCH_SERVICE_NAME}.search.windows.net"
KB_API_VER="2025-11-01-preview"
AGENT_API_VER="2025-05-15-preview"
SEARCH_ADMIN_KEY=$(az search admin-key show --service-name "$SEARCH_SERVICE_NAME" -g "$SPOKE_RG" --query primaryKey -o tsv)

AI_SERVICES_ID=$(az cognitiveservices account show -g "$SPOKE_RG" -n "$AI_SERVICES_NAME" --query id -o tsv)
AOAI_ENDPOINT="https://${AI_SERVICES_NAME}.cognitiveservices.azure.com"

SEARCH_MI=$(az search service show -g "$SPOKE_RG" -n "$SEARCH_SERVICE_NAME" --query identity.principalId -o tsv)
PROJECT_MI=$(az cognitiveservices account show -g "$SPOKE_RG" -n "$AI_SERVICES_NAME" --query identity.principalId -o tsv)
SEARCH_ID=$(az search service show -g "$SPOKE_RG" -n "$SEARCH_SERVICE_NAME" --query id -o tsv)

echo "─── Config ───"
echo "  Search service:    $SEARCH_SERVICE_NAME ($SEARCH_ENDPOINT)"
echo "  Search MI:         $SEARCH_MI"
echo "  AI Services:       $AI_SERVICES_NAME"
echo "  Project MI:        $PROJECT_MI"
echo "  Foundry project:   $FOUNDRY_PROJECT_NAME"
echo "  Index:             $IDX"
echo "  Knowledge Source:  $KS_NAME"
echo "  Knowledge Base:    $KB_NAME  (planner=$PLANNER_MODEL, effort=$REASONING_EFFORT, mode=$OUTPUT_MODE)"
echo "  New agent:         $KB_AGENT_NAME  (existing ${FOUNDRY_AGENT_NAME:-N/A} untouched)"
echo ""

###############################################################################
# Cleanup branch
###############################################################################
if [ "${CLEANUP:-0}" = "1" ]; then
  echo "─── CLEANUP ───"
  curl -sS -X DELETE -H "api-key: $SEARCH_ADMIN_KEY" \
    "${SEARCH_ENDPOINT}/knowledgebases/${KB_NAME}?api-version=${KB_API_VER}" \
    -o /dev/null -w "  KB delete: %{http_code}\n" || true
  curl -sS -X DELETE -H "api-key: $SEARCH_ADMIN_KEY" \
    "${SEARCH_ENDPOINT}/knowledgesources/${KS_NAME}?api-version=${KB_API_VER}" \
    -o /dev/null -w "  KS delete: %{http_code}\n" || true
  echo "  Agent delete: run manually if desired:"
  echo "    az rest --method DELETE --url 'https://${AI_SERVICES_NAME}.services.ai.azure.com/api/projects/${FOUNDRY_PROJECT_NAME}/agents/${KB_AGENT_NAME}?api-version=${AGENT_API_VER}' --resource https://ai.azure.com"
  echo "  Project conn delete (if created):"
  echo "    az rest --method DELETE --url 'https://management.azure.com${AI_SERVICES_ID}/projects/${FOUNDRY_PROJECT_NAME}/connections/${PROJECT_CONN_NAME}?api-version=2025-10-01-preview'"
  exit 0
fi

###############################################################################
# Step 1: RBAC
###############################################################################
echo "─── Step 1: RBAC ───"
# Search MI → Cognitive Services User on AI Services (so KB can call planner LLM)
az role assignment create \
  --assignee-object-id "$SEARCH_MI" --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" --scope "$AI_SERVICES_ID" \
  --output none 2>/dev/null \
  && echo "  ✅ Search MI → Cognitive Services User on AI Services" \
  || echo "  ℹ️  Search MI role already exists (or race)"

# Project MI → Search Index Data Reader on Search (so agent can query KB)
az role assignment create \
  --assignee-object-id "$PROJECT_MI" --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Reader" --scope "$SEARCH_ID" \
  --output none 2>/dev/null \
  && echo "  ✅ Project MI → Search Index Data Reader on Search" \
  || echo "  ℹ️  Project MI Search Index Data Reader already exists"

# Project MI also needs Search Service Contributor to read the KB definition
az role assignment create \
  --assignee-object-id "$PROJECT_MI" --assignee-principal-type ServicePrincipal \
  --role "Search Service Contributor" --scope "$SEARCH_ID" \
  --output none 2>/dev/null \
  && echo "  ✅ Project MI → Search Service Contributor on Search" \
  || echo "  ℹ️  Project MI Search Service Contributor already exists"
echo ""
echo "  (RBAC may take ~2 min to propagate)"
sleep 30
echo ""

###############################################################################
# Step 2: Create Knowledge Source
###############################################################################
echo "─── Step 2: Knowledge Source ($KS_NAME) ───"
KS_BODY=$(cat <<EOF
{
  "name": "${KS_NAME}",
  "kind": "searchIndex",
  "description": "SharePoint index wrapper for agentic retrieval",
  "searchIndexParameters": {
    "searchIndexName": "${IDX}",
    "sourceDataFields": [
      { "name": "title" },
      { "name": "chunk" },
      { "name": "url" }
    ]
  }
}
EOF
)
KS_HTTP=$(curl -sS -o /tmp/ks-resp.json -w "%{http_code}" \
  -X PUT "${SEARCH_ENDPOINT}/knowledgesources/${KS_NAME}?api-version=${KB_API_VER}" \
  -H "api-key: $SEARCH_ADMIN_KEY" -H "Content-Type: application/json" \
  --data "$KS_BODY")
if [[ "$KS_HTTP" =~ ^20[0-9]$ ]]; then
  echo "  ✅ KS created/updated (HTTP $KS_HTTP)"
else
  echo "  ❌ KS failed (HTTP $KS_HTTP):"
  cat /tmp/ks-resp.json; echo
  exit 1
fi
echo ""

###############################################################################
# Step 3: Create Knowledge Base
###############################################################################
echo "─── Step 3: Knowledge Base ($KB_NAME) ───"
KB_BODY=$(cat <<EOF
{
  "name": "${KB_NAME}",
  "description": "Agentic retrieval KB over SharePoint",
  "knowledgeSources": [ { "name": "${KS_NAME}" } ],
  "models": [
    {
      "kind": "azureOpenAI",
      "azureOpenAIParameters": {
        "resourceUri": "${AOAI_ENDPOINT}",
        "deploymentId": "${PLANNER_MODEL}",
        "modelName": "${PLANNER_MODEL}"
      }
    }
  ],
  "retrievalReasoningEffort": { "kind": "${REASONING_EFFORT}" },
  "outputMode": "${OUTPUT_MODE}"
}
EOF
)
KB_HTTP=$(curl -sS -o /tmp/kb-resp.json -w "%{http_code}" \
  -X PUT "${SEARCH_ENDPOINT}/knowledgebases/${KB_NAME}?api-version=${KB_API_VER}" \
  -H "api-key: $SEARCH_ADMIN_KEY" -H "Content-Type: application/json" \
  --data "$KB_BODY")
if [[ "$KB_HTTP" =~ ^20[0-9]$ ]]; then
  echo "  ✅ KB created/updated (HTTP $KB_HTTP)"
else
  echo "  ❌ KB failed (HTTP $KB_HTTP):"
  cat /tmp/kb-resp.json; echo
  exit 1
fi
echo ""

###############################################################################
# Step 4: Smoke test — retrieve directly (bypasses Foundry, proves KB works)
###############################################################################
echo "─── Step 4: Direct retrieve smoke test ───"
TEST_QUERY="${TEST_QUERY:-what documents do you have about procurement?}"
RETRIEVE_BODY=$(cat <<EOF
{
  "messages": [
    { "role": "user", "content": [ { "type": "text", "text": "${TEST_QUERY}" } ] }
  ],
  "knowledgeSourceParams": [
    {
      "kind": "searchIndex",
      "knowledgeSourceName": "${KS_NAME}",
      "includeReferences": true,
      "includeReferenceSourceData": true
    }
  ]
}
EOF
)
echo "  Query: \"$TEST_QUERY\""
RETR_HTTP=$(curl -sS -o /tmp/retr-resp.json -w "%{http_code}" \
  -X POST "${SEARCH_ENDPOINT}/knowledgebases/${KB_NAME}/retrieve?api-version=${KB_API_VER}" \
  -H "api-key: $SEARCH_ADMIN_KEY" -H "Content-Type: application/json" \
  --data "$RETRIEVE_BODY")
if [[ "$RETR_HTTP" =~ ^20[0-9]$ ]]; then
  echo "  ✅ Retrieve OK (HTTP $RETR_HTTP)"
  echo "  --- Response summary ---"
  python3 - <<'PY'
import json
d = json.load(open("/tmp/retr-resp.json"))
resp = d.get("response", [])
acts = d.get("activity", [])
refs = d.get("references", [])
print(f"  response blocks: {len(resp)}")
if resp:
    first_text = resp[0].get("content", [{}])[0].get("text", "")
    print(f"  first text: {first_text[:300]}...")
print(f"  subqueries / activity steps: {len(acts)}")
for a in acts[:5]:
    t = a.get("type", "?")
    if t == "searchIndex":
        print(f"    - searchIndex subquery: {a.get('searchIndexArguments',{}).get('search','?')[:120]}")
    else:
        print(f"    - {t}")
print(f"  references (docs returned): {len(refs)}")
for r in refs[:3]:
    sd = r.get("sourceData", {})
    print(f"    - title={sd.get('title','?')}  url={sd.get('url','?')}")
PY
else
  echo "  ❌ Retrieve failed (HTTP $RETR_HTTP):"
  cat /tmp/retr-resp.json; echo
  echo ""
  echo "  Common causes:"
  echo "   - RBAC not yet propagated — wait 2 min and retry"
  echo "   - Planner model not in region or not deployed"
  echo "   - Semantic ranker disabled"
  exit 1
fi
echo ""

###############################################################################
# Step 5: Foundry project connection (RemoteTool → KB MCP endpoint)
###############################################################################
echo "─── Step 5: Foundry project connection ($PROJECT_CONN_NAME) ───"
MCP_ENDPOINT="${SEARCH_ENDPOINT}/knowledgebases/${KB_NAME}/mcp?api-version=${KB_API_VER}"
echo "  MCP endpoint: $MCP_ENDPOINT"

ARM_TOKEN=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)
CONN_BODY=$(cat <<EOF
{
  "name": "${PROJECT_CONN_NAME}",
  "type": "Microsoft.MachineLearningServices/workspaces/connections",
  "properties": {
    "authType": "ProjectManagedIdentity",
    "category": "RemoteTool",
    "target": "${MCP_ENDPOINT}",
    "isSharedToAll": true,
    "audience": "https://search.azure.com/",
    "metadata": { "ApiType": "Azure" }
  }
}
EOF
)
CONN_URL="https://management.azure.com${AI_SERVICES_ID}/projects/${FOUNDRY_PROJECT_NAME}/connections/${PROJECT_CONN_NAME}?api-version=2025-10-01-preview"
CONN_HTTP=$(curl -sS -o /tmp/conn-resp.json -w "%{http_code}" \
  -X PUT "$CONN_URL" \
  -H "Authorization: Bearer $ARM_TOKEN" -H "Content-Type: application/json" \
  --data "$CONN_BODY")
if [[ "$CONN_HTTP" =~ ^20[0-9]$ ]]; then
  echo "  ✅ Project connection created/updated (HTTP $CONN_HTTP)"
  CONN_ID=$(python3 -c "import json; print(json.load(open('/tmp/conn-resp.json')).get('id',''))")
  echo "  Connection ID: $CONN_ID"
else
  echo "  ❌ Project connection failed (HTTP $CONN_HTTP):"
  cat /tmp/conn-resp.json; echo
  exit 1
fi
echo ""

###############################################################################
# Step 6: Create Foundry agent with MCP tool
###############################################################################
echo "─── Step 6: Foundry agent ($KB_AGENT_NAME) ───"
FOUNDRY_ENDPOINT="https://${AI_SERVICES_NAME}.services.ai.azure.com/api/projects/${FOUNDRY_PROJECT_NAME}"
AGENT_TOKEN=$(az account get-access-token --resource "https://ai.azure.com" --query accessToken -o tsv)

AGENT_INSTRUCTIONS=$'You are a grounded SharePoint assistant.\n\n- For every user question, call the knowledge_base_retrieve tool first.\n- Answer ONLY from the tool results. Never from general knowledge.\n- Cite sources using the returned `references` (title + url).\n- Reply in the user\'s language (Hebrew in → Hebrew out).\n- If the tool returns nothing relevant, say: "I don\'t know — not in the knowledge source."'

AGENT_BODY=$(AGENT_INSTR="$AGENT_INSTRUCTIONS" AGENT_MODEL_ENV="${FOUNDRY_AGENT_MODEL:-gpt-4.1}" CONN_ID="$CONN_ID" MCP_URL="$MCP_ENDPOINT" \
  python3 -c "
import json, os
body = {
  'definition': {
    'kind': 'prompt',
    'model': os.environ['AGENT_MODEL_ENV'],
    'instructions': os.environ['AGENT_INSTR'],
    'tools': [{
      'type': 'mcp',
      'server_label': 'knowledge_base',
      'server_url': os.environ['MCP_URL'],
      'require_approval': 'never',
      'allowed_tools': ['knowledge_base_retrieve'],
      'project_connection_id': os.environ['CONN_ID']
    }]
  }
}
print(json.dumps(body))")

AGENT_HTTP=$(curl -sS -o /tmp/agent-resp.json -w "%{http_code}" \
  -X POST "${FOUNDRY_ENDPOINT}/agents/${KB_AGENT_NAME}/versions?api-version=${AGENT_API_VER}" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  --data "$AGENT_BODY")

if [[ "$AGENT_HTTP" =~ ^20[0-9]$ ]]; then
  AGENT_VER=$(python3 -c "import json; print(json.load(open('/tmp/agent-resp.json')).get('version','?'))")
  echo "  ✅ Agent '${KB_AGENT_NAME}' version ${AGENT_VER} created"
  echo "     Model:     ${FOUNDRY_AGENT_MODEL:-gpt-4.1}"
  echo "     Tool:      mcp → ${KB_NAME} (agentic retrieval)"
else
  echo "  ⚠️  Agent creation failed (HTTP $AGENT_HTTP):"
  cat /tmp/agent-resp.json; echo
  echo ""
  echo "  Debug: inspect the failing request body:"
  echo "$AGENT_BODY" | python3 -m json.tool
  exit 1
fi
echo ""

###############################################################################
# Done
###############################################################################
echo "============================================"
echo " ✅ Agentic retrieval prototype ready!"
echo "============================================"
echo ""
echo " Next steps:"
echo " 1. Open https://ai.azure.com → project '${FOUNDRY_PROJECT_NAME}'"
echo " 2. Playground → select agent '${KB_AGENT_NAME}' (NOT '${FOUNDRY_AGENT_NAME:-the other one}')"
echo " 3. Ask the same questions you use with '${FOUNDRY_AGENT_NAME:-current agent}' and compare:"
echo "    - Answer quality"
echo "    - Citation rendering (should be clean 【n:m†src】 markers)"
echo "    - Latency"
echo ""
echo " Re-run this script to update KB/agent definition."
echo " Set CLEANUP=1 to tear down KS+KB (agent must be deleted manually)."
echo "============================================"
