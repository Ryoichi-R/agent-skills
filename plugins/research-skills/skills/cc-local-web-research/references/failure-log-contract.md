# cc-local-web-research failure log contract

## Primary evidence

The finalized research Markdown and its schema-version log are primary evidence
for `complete`. A handled finalize or validation failure keeps only a small
`failure-summary.json`; invalid Markdown, raw stdout/stderr, command lines, and
environment variables are not retained.

Local-only or Web-only completion is a documented degraded path, not a terminal
`partial` status. Record the limitation in the research output itself.

## Expected artifacts manifest

`scripts/finalize-research-output.ps1` creates
`result/research/.run-state/<timestamp>/expected-artifacts.manifest.json` before
validation. It updates `observed_status` to `complete` or `failed` and declares
exact relative paths for:

| Artifact                  | Required status |
| ------------------------- | --------------- |
| `research_<timestamp>.md` | `complete`      |
| schema-version log        | `complete`      |
| `failure-summary.json`    | `failed`        |

The manifest follows
`src/shared/contracts/skill-expected-artifacts.schema.json`. The workspace
scanner reports `observability_gap` only when a required artifact is missing;
the manifest does not duplicate a failure when safe evidence exists.

## Sensitive data

`failure-summary.json` contains only `schema_version`, UTC `timestamp`, `skill`,
`run_id`, and a fixed reason code. Do not add exception text or user content to
that file without applying the shared redaction rules first.
