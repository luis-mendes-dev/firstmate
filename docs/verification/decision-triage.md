# Decision triage verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-decision-triage.sh` contract owned by [`../configuration.md`](../configuration.md) ("Decision triage") and the decision policy owned by [`ask-user-authority`](../../.agents/skills/ask-user-authority/SKILL.md).
It records only facts that must be re-established when the typesafe.ai model, its API, or the triage policy changes.
The API facts this tool depends on are the same ones recorded in [`dispatch-resolve.md`](dispatch-resolve.md), which remains their single owner; only the parts specific to triage are repeated here.

## The API surface triage adds

`POST /v1/systemone` accepts more than one question in the `questions` object and answers each under its own key in `answers`, which is what lets triage ask `class` and `answer` in one request instead of two.
Both answers are ordinary `choice` answers with the `{choice, probabilities, confidence}` shape already verified for dispatch resolution.

## Shared transport

`bin/fm-jev-lib.sh` is the single owner of the opt-in gate, the fixed endpoint, model, five-second timeout, 0.6 confidence floor, and the secret boundary for both Jev callers.
`tests/fm-dispatch-resolve.test.sh` continues to pass unchanged against the extracted transport, which is the regression evidence that dispatch resolution's own contract - absent-key off, key absent from every child environment, key never on argv, key only on the descriptor header, fixed endpoint and timeout - survived the extraction.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
```

## Offline behavior

Verified 2026-09-21 on macOS 25.6.0 with ShellCheck 0.11.0.

`tests/fm-decision-triage.test.sh` drives the public argv, stdin, and environment interface with a fake `curl` that records argv, the request body, the header read from file descriptor 3, and whether the secret reached its environment.
It proves the absent key (environment and `.env`) prints one stderr line, nothing on stdout, exits 0, never invokes `curl`, and writes no record, while a `.env` key turns the tool on and the environment wins over it.
It proves the key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor, and that the request uses the fixed endpoint, model, and five-second timeout from the shared transport.
It proves one POST carries both the `class` and `answer` Choices, that the answer options are exactly the caller's own ids plus the fixed `escalate` option, and that the task, accepted intent, and caller evidence ride in the state.
It proves the deterministic pre-gate escalates merge, destructive, irreversible, security, schema, and product decisions with the matched text published and no model call at all, and that a non-routine class or an `escalate` answer escalates without publishing a resolution or a send command.
It proves a `resolve` publishes the caller's own option text as the resolution and the exact `fm-send --resolve-key` command, shell-quoted.
It proves either confidence below the shared floor is `ambiguous` rather than a resolution.
It proves secret-shaped evidence and evidence over `FM_TRIAGE_EVIDENCE_MAX` are refused with exit 2 before any network call and write no record.
It proves that with no caller intent the task brief's `## Captain's intent` subsection becomes the accepted contract while the firstmate spec does not, and that the brief is listed in the evidence manifest as the intent's provenance.
It proves every completed triage appends a dated rationale and provenance block, that a second run appends rather than overwrites, and that an `error` outcome writes no record.
It proves HTTP failures, transport failures, malformed responses, and missing `curl` are structured `error` outcomes with exit 0, while unreadable, non-JSON, and each malformed-document shape exit 2 before any network call.

```console
$ bash tests/fm-decision-triage.test.sh | tail -1
# all fm-decision-triage tests passed
```

A live run needs a key and is not part of the suite; point the tool at a real decision document with the key injected for that one command.
