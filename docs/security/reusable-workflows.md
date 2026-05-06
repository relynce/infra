# Reusable Security Workflows

Org-wide SAST, SCA, and DAST pipelines that any Revelara repo can call. Designed to produce the artifacts a CASA Tier 2 assessor expects (SARIF reports for SAST/SCA, ZAP HTML/JSON reports for DAST) without copy-pasting workflow files across repos.

## What's here

| File | Purpose |
| --- | --- |
| `.github/workflows/sast.yml` | Semgrep (OWASP Top 10, secrets, lang rulesets) + gosec |
| `.github/workflows/sca.yml` | Trivy filesystem scan + govulncheck (Go-aware) |
| `.github/workflows/dast.yml` | OWASP ZAP baseline/full scan with optional bearer-token auth |
| `.github/workflows/security-suite.yml` | Orchestrator that runs all three |

All four are `workflow_call` reusable workflows.

## One-time GitHub setup

Reusable workflows in a private repo are not callable from other private repos in the same org by default. Enable cross-repo access on `revelara-ai/infra`:

1. Repo Settings → Actions → General
2. **Access** → "Accessible from repositories owned by the 'revelara-ai' organization"
3. Save

This change is not in code. It only needs to be done once on `infra`.

## Wiring a new repo

Add a workflow that calls the orchestrator. Minimal example:

```yaml
# .github/workflows/security.yml
name: Security
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  schedule:
    - cron: "0 8 * * 1"  # Monday 08:00 UTC for full-scan runs

permissions:
  contents: read
  security-events: write
  issues: write
  pull-requests: write

jobs:
  suite:
    uses: revelara-ai/infra/.github/workflows/security-suite.yml@main
    with:
      go-version: "1.25"
      scan-go: true
      run-dast: ${{ github.event_name == 'schedule' }}
      dast-target-url: https://dev.example.revelara.ai
      dast-mode: ${{ github.event_name == 'schedule' && 'full' || 'baseline' }}
    secrets:
      dast-bearer-token: ${{ secrets.DAST_BEARER_TOKEN }}
```

For a TS-only repo (no Go), set `scan-go: false`.

## DAST authentication

Revelara enforces auth on every endpoint, so unauthenticated DAST only covers the login surface. The reusable DAST workflow injects a Bearer token into every request via ZAP's HTTP-replacer.

Polaris accepts API keys as `Authorization: Bearer pk_<...>` (`internal/middleware/api_key.go`), which sidesteps WorkOS SSO for programmatic clients. Use an API key, not a JWT.

### Minting the DAST API key

Per app, once:

1. Log in to the dev environment (`https://dev.revelara.ai`) with a WorkOS account.
2. Navigate to **Settings → API Keys**.
3. Create a key named `DAST Bot` with these scopes (covers the full HTTP surface so ZAP probes every endpoint):
   - `admin:organization`
   - `read:*`, `write:*` for documents, conversations, knowledge, search, risks
4. Copy the plaintext key (shown once, format `pk_live_...`).
5. Store it as a repo secret on the caller (e.g. polaris):
   ```bash
   gh secret set DAST_BEARER_TOKEN -R revelara-ai/polaris
   # paste the key at the prompt; it is never echoed and never persisted to shell history
   ```

### Test account hygiene

- Use a **dedicated organization** in dev (no real data) so ZAP probes can't pollute working state. Create one via Settings → Organizations or seed it via SQL.
- Tag the API key's `metadata` with `{"purpose": "dast"}` so it's grep-able for audit and rotation.
- Rotate the key quarterly. ZAP findings get less reliable over time as the dev surface drifts; rotation is also a forcing function to re-verify the scan still works.
- **Never use migration 029's published demo key** (`pk_live_rc11sSzl...`) for DAST or any environment reachable from the internet. It's checked into the repo and provides zero secret hygiene.

## Reading the reports

| Tool | Where to look |
| --- | --- |
| Semgrep, gosec, Trivy | Repo → Security tab → Code scanning |
| govulncheck | Workflow run artifacts (`govulncheck-json`) |
| ZAP | Workflow run artifacts (`zap_scan` HTML + JSON) |

For a CASA assessment package, download the latest run's artifacts and the Security-tab SARIF dumps. That's the reviewer-ready evidence bundle.

## Tuning out noise

Findings that aren't true positives should be suppressed at the source, not by lowering severity thresholds:

- **Semgrep**: add a `.semgrepignore` at repo root or inline `# nosemgrep: rule-id` comments.
- **gosec**: `// #nosec G404 -- reason` annotations.
- **Trivy**: `.trivyignore` at repo root, one CVE per line with a comment.
- **govulncheck**: usually no false positives because it tracks call-graph reachability — if it fires, fix it.

## CASA mapping

The scanners cover the bulk of the ASA-WG v2.0.0 verification requirements:

| ASA section | Covered by |
| --- | --- |
| Authentication, session management | Semgrep (auth rulesets), gosec (G401-G404), DAST (auth flow) |
| Access control | DAST (authenticated probing) |
| Input validation, encoding | Semgrep (OWASP Top 10), DAST (XSS/SQLi probes) |
| Cryptography | gosec (G401-G411), Semgrep (crypto rulesets) |
| Error handling, logging | Semgrep (error patterns) |
| Data protection | Semgrep secrets, Trivy secrets |
| Communications security | DAST (TLS, security headers) |
| Malicious code, supply chain | Trivy, govulncheck, Dependabot |
| Business logic, files | Manual review (no scanner coverage; document in ASA self-assessment) |
| Configuration | Trivy misconfig, Semgrep dockerfile/github-actions |

The "manual review" rows are addressed by the CASA self-assessment questionnaire, not by tooling.

## Pinning and updates

Workflows are referenced as `@main`. Once the rollout is stable across repos:

1. Tag `infra` with a version (e.g. `security-v1.0.0`).
2. Update callers to `@security-v1.0.0`.
3. Bump tag when changing scanner versions or rule sets.

This protects callers from accidental breakage when iterating on the workflows.
