# Making Foundry agents show real SharePoint citation URLs

**TL;DR** — When you use the `azure_ai_search` tool in a Microsoft Foundry
agent against an index built from SharePoint content, the citation chip
(`[1]`) in the Playground UI links to
`https://<search>.search.windows.net/` instead of the real SharePoint
document URL. Documented `fields_mapping.url_field` is silently ignored at
runtime, and Foundry's citation post-processor actively rewrites any
markdown link `[text](url)` the model emits. The reliable workaround is to
have the model print the real URL as a **bare plain URL on its own line**
(no markdown, no backticks, no bold) — Playground auto-linkifies it and
Foundry's rewriter leaves it alone.

---

## The setup

- **Pipeline**: SharePoint → Function App → Blob container →
  Azure AI Search indexer (skillset: OCR → merge → split → embed) → index
  `sharepoint-index`.
- Index has custom fields including `url` (populated via indexer
  `fieldMappings` from `sharepoint_web_url` blob metadata) and `title`.
- **Foundry agent** uses the `azure_ai_search` tool wired to the index
  via a project connection. `query_type: simple`.

Direct queries against the index (via VPN or VNet) return perfect data —
every document has `url = https://mngenvmcap338326.sharepoint.com/...`.

## The problem

In Playground, answers look great but citations point to the Search
service endpoint, not SharePoint:

```
...כל החברים מתמנים במעמד בכיר[1].

[1] → https://aiservicesrzgnsearch.search.windows.net/
```

Clicking the chip opens the Search service root instead of the source
document. This is a dealbreaker for any real business use.

## What we tried (and why it failed)

### Attempt 1 — Prompt engineering

Tell the model to cite the real URL. No effect: the model *does* emit
the correct markdown link, but the UI still shows the wrong URL.

### Attempt 2 — `fields_mapping.url_field` on the tool

The documented way to tell the tool which index field holds the citation
URL:

```json
"fields_mapping": {
  "url_field": "url",
  "title_field": "title",
  "content_fields": ["chunk"]
}
```

Foundry accepts both camelCase (`urlField`) and snake_case
(`url_field`) without error. **At runtime it's ignored.**
The agent trace shows:

```
"get_urls": [
  "https://.../docs/<key>?api-version=2024-07-01&$select=chunk_id,acl_user_ids,acl_group_ids,chunk,title,original_file_name"
]
```

The `$select` is **hardcoded** — our `url` field is never retrieved, so
no amount of field mapping can surface it to the model.

### Attempt 3 — Field hijacking (`original_file_name`)

Since `original_file_name` *is* in Foundry's hardcoded `$select`, we
re-projected the SharePoint URL into that field via the skillset's
`indexProjections.selectors[*].mappings`:

```diff
- { "name": "original_file_name", "source": "/document/metadata_storage_name" }
+ { "name": "original_file_name", "source": "/document/sharepoint_web_url" }
```

Reindexed 920 chunks. Each tool-call result now contained the URL inside
`original_file_name`. **Foundry dropped it** — the tool output shape the
model receives is itself hardcoded:

```json
{ "id": "...", "content": "...", "filepath": "",
  "title": "...", "url": "<search endpoint placeholder>", "score": ... }
```

`original_file_name` is selected but never surfaced to the model.

### Attempt 4 — Use URL embedded in `content`

The skillset emits the chunk text followed by the filename and
SharePoint URL as the last two lines of `content`. Prompt the model to
cite `[title](<URL-from-last-line-of-content>)`. The model streams the
correct link...

> In the first second I see the correct `https://mngenvmcap338326.sharepoint.com/...` link,
> and then something suddenly rewrites it to the wrong one.

### Root cause — the citation rewriter

Foundry's streaming pipeline attaches `url_citation` annotations to the
assistant's text. In Playground, any anchor it recognizes as citation
content — **markdown link syntax `[text](url)`** — gets its URL replaced
by the annotation's URL. That annotation URL is derived from the tool
result's `url` field, which Foundry overrides to the Search service
endpoint. Additionally, bold/italic text (`**text**`) is sometimes
replaced with a `%CITATION_N%` marker.

So anything that looks like a citation anchor (markdown link, bold,
italic) gets rewritten. Plain text passes through untouched.

## The fix that actually works

1. **Skillset indexProjection**: `original_file_name` ← `/document/sharepoint_web_url`
   (ensures the URL reliably appears as the last line of `content` in
   tool results — this also survives chunking).
2. **Agent instructions** tell the model:
   - Extract the URL from the last line of each result's `content`
     (must start with `https://` and contain `sharepoint.com`).
   - **Never** use markdown link `[text](url)`.
   - **Never** use markdown bold `**text**` or italic `*text*`.
   - **Never** wrap the URL in backticks (makes it non-clickable).
   - Print title and URL on two consecutive plain lines:

     ```text
     מקורות:

     המב 50.02 מתן תמיכות מתקציב הביטחון למוסדות ציבור.pdf
     https://mngenvmcap338326.sharepoint.com/sites/lab511-demo/Shared%20Documents/Malan/...pdf
     ```

Playground's Markdown renderer auto-linkifies bare URLs, and the
citation rewriter leaves bare URLs alone. The chip on the inline `[1]`
still shows the Search placeholder (can't fix from the API side), but
the "מקורות" section below the answer has real, clickable SharePoint
URLs.

## Prompt fragment (copy-paste ready)

```text
Citation output format — CRITICAL (Foundry post-processes your output
and will break anything it recognizes as a citation anchor):
- DO NOT use markdown link syntax [text](url). Foundry overwrites the URL.
- DO NOT use markdown bold or italic (**text** or *text*). Foundry
  replaces styled text with a citation marker (%CITATION_N%).
- DO NOT wrap the URL in backticks (that makes it non-clickable).
- DO print the URL as a bare, plain URL on its own line. The Playground
  markdown renderer auto-linkifies bare URLs, and the citation rewriter
  leaves them alone.

At the end of your answer, on a new paragraph, write the exact heading
line:
מקורות:

Then, for each distinct document you cited, print TWO consecutive lines:
  Line 1: the plain document title (no markdown, no bold, no backticks).
  Line 2: the bare SharePoint URL (no markdown, no backticks, no
          surrounding text — just the URL).
Leave a blank line between sources.
```

## Open question

The inline `[N]` chip URL still comes from the tool result's `url`
field, which Foundry hardcodes to the Search service endpoint. The
documented knobs (`fields_mapping.url_field`) don't change this at
runtime. Until Foundry honors `fields_mapping` or exposes a way to
override `url`, the "Sources" block with bare URLs is the most robust
way to give users a working link.

## Files in this repo

- [deployment/3-deploy-sharepoint-sync.sh](../../deployment/3-deploy-sharepoint-sync.sh) — deploy script (indexer
  `fieldMappings`, skillset `indexProjections`, agent instructions).
