# Upstream source

This folder is a vendored copy of the Microsoft sample repo:

- **Source:** https://github.com/Azure-Samples/sharepoint-foundryIQ-secure-sync
- **Path in upstream:** `src/sync/`
- **Vendored at commit:** `2afa0beed107671e1fc4c39afb4ccfda5ae8c1dd`
- **Upstream commit date:** 2026-04-07 16:11:40 +0200
- **Vendored on:** 2026-04-17T12:44:20Z

## Why vendored?

- Deploy must not depend on upstream being available (repo deletion, privacy change, network outage).
- Local patches (extra triggers, filter fixes) are committed alongside upstream code so diffs are obvious.

## Local modifications vs. upstream

Tracked in git history under `roie9876/Azure-AI-Foundry-Networking`. To see diffs:

```bash
git log --follow deployment/sharepoint-sync-func/
```

## Updating from upstream

```bash
cd deployment
git clone https://github.com/Azure-Samples/sharepoint-foundryIQ-secure-sync .upstream-tmp
# Review diff, merge manually:
diff -r .upstream-tmp/src/sync/ sharepoint-sync-func/
rm -rf .upstream-tmp
```
