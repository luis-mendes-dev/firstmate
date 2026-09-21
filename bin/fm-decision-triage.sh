#!/usr/bin/env bash
# fm-decision-triage.sh - triage ONE open worker decision with typesafe.ai's
# System One model (Jev), opt-in, so firstmate answers routine evidence-backed
# questions in one short tool turn and escalates everything else to the captain.
#
# Usage:
#   fm-decision-triage.sh <decision-json-file | -> [--json]
#
# HARNESS INDEPENDENT BY CONSTRUCTION. This is a firstmate-layer flow, not
#   worker autonomy: the worker raises `needs-decision [key=<key>]` exactly as
#   it does today, firstmate writes the decision document and runs this tool,
#   and the answer goes back through bin/fm-send.sh --resolve-key. Nothing here
#   knows or cares which harness raised the decision, so Claude Code, OpenCode,
#   Codex, and Pi workers all reach the same triage.
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env. The environment wins.
#   bin/fm-jev-lib.sh owns that gate, the endpoint/model/timeout/floor
#   constants, and the secret boundary. Absent in both: one
#   "decision-triage: off" line on stderr, nothing on stdout, exit 0, no
#   network call, so firstmate decides exactly as it does today.
#
# INPUT CONTRACT, one JSON object (path, or `-` for stdin):
#   {
#     "task":     "<task-id>",              required, [A-Za-z0-9._-]
#     "key":      "<decision-key>",         required, the open key from the
#                                           worker's needs-decision: line
#     "question": "<verbatim decision text>",   required
#     "options":  [ {"id": "fix", "answer": "<the exact answer text to send>"} ],
#                                           required, at least one, unique
#                                           lowercase ids, never "escalate"
#     "intent":   "<the accepted contract>",    optional; when absent the task
#                                           brief's `## Captain's intent`
#                                           subsection is read as repository
#                                           evidence and used instead
#     "evidence": [ {"source": "<path, range, or URL>", "text": "<excerpt>"} ]
#                                           optional; repository excerpts and
#                                           public research the CALLER
#                                           collected, because only the calling
#                                           agent has the tools to gather them
#   }
#   The model chooses among the caller's own option texts; it never authors the
#   answer that gets sent. With no options there is nothing to choose and the
#   decision escalates.
#
# EVIDENCE BOUNDARIES, enforced before the network call:
#   Total question, intent, and evidence bytes are capped at
#   FM_TRIAGE_EVIDENCE_MAX (default 65536); over the cap is an exit 2 the
#   caller trims rather than selects around.
#   Anything matching the secret shapes below is refused with exit 2 instead of
#   being sent to the API. This tool reads no credential file of its own.
#
# DETERMINISTIC POLICY CLASSIFICATION, in this order:
#   1. A pre-gate regex over question + intent + option answers. A match on
#      merge, destructive, irreversible, security, schema, or product language
#      escalates with the matched text recorded and NO model call. The pre-gate
#      can only escalate; it can never clear a decision.
#   2. Jev answers two Choice questions in one POST: `class` (routine or one of
#      the escalate classes) and `answer` (one of the caller's option ids, or
#      the fixed `escalate` option).
#   3. Code, not the model, decides: `resolve` needs class `routine`, an answer
#      other than `escalate`, and BOTH confidences at or above
#      FM_JEV_CONFIDENCE_FLOOR. Everything else escalates or is ambiguous.
#
# Output (stdout, TOON-style block; --json emits the raw result object):
#   decision-triage:
#     status: resolve | escalate | ambiguous | error
#     task/key, model/latency_ms/tokens, class and answer with probabilities
#     evidence: the manifest actually sent, each item with its sha256 and bytes
#     reason: <why the status is not resolve>
#     record: <durable rationale and provenance file>
#     resolution: <the chosen option's own answer text>            (resolve only)
#     command: bin/fm-send.sh <task> --resolve-key <key> <answer>  (resolve only)
#   resolve   -> run that command after reading the rationale; fm-send closes
#                the open decision at answer time, which is the existing
#                durable decision flow and the only one this tool feeds
#   escalate  -> the captain's call; ask-user-authority owns how to put it
#   ambiguous -> below the confidence floor; decide as today
#   error     -> API, network, or response failure; decide as today
#   Every outcome exits 0 so a decision is never blocked by this tool.
#   Exit 2 only for a usage, input, or boundary error, which is actionable.
#
# Durable rationale and provenance: one appended block per run in
#   $FM_HOME/data/<task>/triage-<key>.md (FM_DATA_OVERRIDE selects the data
#   directory), recording the UTC time, status, pre-gate result, class, answer,
#   confidences, model, latency, tokens, the evidence manifest with digests,
#   and the resolution text. An `error` outcome writes no record because it
#   established nothing.
#
# AUTHORITY. This tool recommends; it never acts. It does not send, merge,
#   close a decision, touch a project, or answer its own escalation, and it is
#   never authority for a merge, a secret, a destructive or irreversible
#   action, a security tradeoff, a schema or product change, or a genuinely
#   ambiguous finding. .agents/skills/ask-user-authority/SKILL.md owns the
#   decision policy this serves, and docs/configuration.md "Decision triage"
#   owns the operator contract.
set -u

# FIRST, before any source line can run an external command that would inherit
# the secret. bin/fm-jev-lib.sh owns the rest of that boundary.
FM_JEV_KEY=${TYPESAFE_API_KEY:-}
export -n FM_JEV_KEY 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

EVIDENCE_MAX=${FM_TRIAGE_EVIDENCE_MAX:-65536}
ID_RE='^[A-Za-z0-9._-]+$'
OPTION_ID_RE='^[a-z0-9][a-z0-9_-]*$'

# Shapes that must never leave this machine in a request body.
SECRET_RE='(TYPESAFE_API_KEY|FMX_PAIRING_TOKEN|Authorization: Bearer |-----BEGIN [A-Z ]*PRIVATE KEY-----|(api[_-]?key|secret|token|password|passwd)[[:space:]]*[=:][[:space:]]*[^[:space:]]{8,})'

# The deterministic pre-gate: class<TAB>extended regex, matched case-insensitively
# over question + intent + option answers. Each pattern names work the captain
# owns outright, so a match escalates without a model call. Tight on purpose:
# these match destroying real state, not ordinary prose about deleting a helper.
PREGATE=(
  $'merge\t(merge (this|the|a) |merging (this|the) |land (this|the) (pr|branch|work)|fast-forward (this|the|onto)|--allow-red|cut (a|the) release|publish (the|a) (release|package))'
  $'destructive\t(rm -rf|force[- ]pushe?d?|git push --force|--force-with-lease|drop (table|column|database|index)|truncate table|delete (the )?(production|user|customer)|purge (the )?(data|database)|wipe (the )?(data|disk|volume))'
  $'irreversible\t(irreversible|cannot be undone|can not be undone|unrecoverab|permanent data loss|one-way (door|migration)|(data|schema) migration|backfill)'
  $'security\t(credential|api key|secret key|private key|password|auth token|access token|privilege escalation|sandbox escape|vulnerab|CVE-[0-9]|threat model|attack surface)'
  $'schema\t(wire format|on-disk format|database schema|schema change|protocol version|breaking change|backwards? incompatib|public api contract)'
  $'product\t(product (decision|direction|strategy)|pricing|user-facing (behaviou?r|change)|what (the )?(users|customers) (see|get)|rename the product)'
)

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

INPUT='' AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) AS_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -) [ -z "$INPUT" ] || die "one decision document only"; INPUT='-'; shift ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$INPUT" ] || die "one decision document only"; INPUT=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
if ! fm_jev_gate "$FM_HOME"; then
  echo "decision-triage: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

# ---- input ---------------------------------------------------------------------
[ -n "$INPUT" ] || die "decision document required (see --help)"
command -v jq >/dev/null 2>&1 || die "jq required"
DOC=$(mktemp) || die "mktemp failed"
RESP_FILE=$(mktemp) || { rm -f "$DOC"; die "mktemp failed"; }
trap 'rm -f "$DOC" "$RESP_FILE"' EXIT
chmod 600 "$DOC" "$RESP_FILE" || die "could not protect scratch files"
if [ "$INPUT" = - ]; then
  cat > "$DOC" || die "could not read the decision document from stdin"
else
  [ -r "$INPUT" ] || die "decision document not readable: $INPUT"
  cp "$INPUT" "$DOC" || die "could not snapshot the decision document: $INPUT"
fi

doc_err=$(jq -r --arg id_re "$ID_RE" --arg opt_re "$OPTION_ID_RE" '
  def nonempty($v): ($v | type) == "string" and ($v | length) > 0;
  # The task and key become path segments of the durable record, so a bare dot
  # run is refused rather than allowed to walk out of the data directory.
  def id_ok($v): nonempty($v) and ($v | test($id_re)) and ($v | test("^\\.+$") | not);
  if type != "object" then "top-level value must be an object"
  elif id_ok(.task) | not then "task must be a task id matching \($id_re)"
  elif id_ok(.key) | not then "key must be a decision key matching \($id_re)"
  elif nonempty(.question) | not then "question must be the non-empty decision text"
  elif (.options | type) != "array" or (.options | length) == 0 then "options must be a non-empty array"
  elif any(.options[]; type != "object" or (nonempty(.id) | not) or (nonempty(.answer) | not)) then "each option needs a non-empty id and answer"
  elif any(.options[]; (.id | test($opt_re)) | not) then "each option id must match \($opt_re)"
  elif any(.options[]; .id == "escalate") then "\"escalate\" is reserved and is offered automatically"
  elif ((.options | map(.id)) | length) != ((.options | map(.id) | unique) | length) then "option ids must be unique"
  elif (.intent // "" | type) != "string" then "intent must be a string when present"
  elif (.evidence // []) | type != "array" then "evidence must be an array when present"
  elif any((.evidence // [])[]; type != "object" or (nonempty(.source) | not) or (nonempty(.text) | not)) then "each evidence item needs a non-empty source and text"
  else empty end
' "$DOC" 2>/dev/null) || die "malformed decision document (not JSON): $INPUT"
[ -z "$doc_err" ] || die "malformed decision document: $doc_err"

TASK=$(jq -r .task "$DOC")
KEY=$(jq -r .key "$DOC")
INTENT=$(jq -r '.intent // ""' "$DOC")
INTENT_SOURCE=caller

# Repository evidence: with no caller-supplied intent, the task brief's own
# `## Captain's intent` subsection is the accepted contract ask-user-authority
# reconstructs first. bin/fm-dod-lib.sh owns reading it.
BRIEF="$DATA/$TASK/brief.md"
if [ -z "$INTENT" ] && [ -f "$BRIEF" ] && [ ! -L "$BRIEF" ]; then
  INTENT=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent" 2>/dev/null || printf '')
  [ -z "$INTENT" ] || INTENT_SOURCE=$BRIEF
fi

# ---- evidence boundaries --------------------------------------------------------
SENT=$(jq -c --arg intent "$INTENT" --arg intent_source "$INTENT_SOURCE" '
  {
    question: .question,
    accepted_intent: $intent,
    options: (.options | map({(.id): .answer}) | add),
    evidence: ((.evidence // []) + (if $intent == "" then [] else [{source: $intent_source, text: $intent}] end))
  }' "$DOC") || die "could not assemble the decision"

BYTES=$(printf '%s' "$SENT" | wc -c | tr -d '[:space:]')
[ "$BYTES" -le "$EVIDENCE_MAX" ] || die "decision and evidence are $BYTES bytes, over the $EVIDENCE_MAX byte cap (FM_TRIAGE_EVIDENCE_MAX); trim the excerpts"
if printf '%s' "$SENT" | grep -Eqi "$SECRET_RE"; then
  die "the decision or its evidence matches a secret shape; nothing was sent. Remove the credential material and retry"
fi

# Provenance manifest: what was actually sent, by source, digest, and size.
digest() {
  local out
  out=$(printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } | cut -c1-16)
  printf '%s' "${out:-unavailable}"
}
MANIFEST='[]'
while IFS= read -r item; do
  [ -n "$item" ] || continue
  src=$(jq -r .source <<<"$item")
  text=$(jq -r .text <<<"$item")
  MANIFEST=$(jq -c --arg s "$src" --arg d "$(digest "$text")" --argjson b "$(printf '%s' "$text" | wc -c | tr -d '[:space:]')" \
    '. + [{source: $s, sha256: $d, bytes: $b}]' <<<"$MANIFEST")
done < <(jq -c '.evidence[]' <<<"$SENT")

# ---- durable rationale and provenance -------------------------------------------
RECORD="$DATA/$TASK/triage-$KEY.md"
write_record() {  # <result-json>
  local dir; dir=$(dirname "$RECORD")
  mkdir -p "$dir" 2>/dev/null || return 0
  jq -r --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg key "$KEY" --argjson manifest "$MANIFEST" '
    def show($v): ($v // "-") | tostring;
    "## \($when)  status=\(.status)",
    "",
    "- key: \($key)",
    "- pre-gate: \(show(.pregate))",
    "- class: \(show(.class)) (confidence \(show(.class_confidence)))",
    "- answer: \(show(.answer)) (confidence \(show(.answer_confidence)))",
    "- model: \(show(.model)), latency \(show(.latency_ms)) ms, tokens \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
    (if .reason then "- reason: \(.reason)" else empty end),
    "- evidence sent:",
    (if ($manifest | length) == 0 then "  - none" else ($manifest[] | "  - \(.source)  sha256:\(.sha256)  \(.bytes) bytes") end),
    (if .resolution then "- resolution: \(.resolution)" else empty end),
    ""' <<<"$1" >> "$RECORD" 2>/dev/null || true
}

emit() {  # <result-json>
  local result=$1
  case "$(jq -r .status <<<"$result")" in error) ;; *) write_record "$result" ;; esac
  if [ "$AS_JSON" = 1 ]; then
    jq -r --arg record "$RECORD" --argjson manifest "$MANIFEST" \
      '. + {record: $record, evidence: $manifest}' <<<"$result"
  else
    jq -r --arg record "$RECORD" --arg task "$TASK" --arg key "$KEY" --argjson manifest "$MANIFEST" '
      def flat: tostring | gsub("[\t\r\n]"; " ");
      def show($v): ($v // "-") | flat;
      def probs($p): if $p == null then "-" else ([$p | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" ")) end;
      "decision-triage:",
      "  status: \(.status | flat)",
      "  task: \($task | flat)   key: \($key | flat)",
      (if .model then "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))" else empty end),
      (if (.pregate // "clear") != "clear" then "  pre-gate: \(.pregate | flat)" else empty end),
      "  class: \(show(.class))   confidence: \(show(.class_confidence))",
      (if .class_probabilities then "  class probabilities: \(probs(.class_probabilities))" else empty end),
      "  answer: \(show(.answer))   confidence: \(show(.answer_confidence))",
      (if .answer_probabilities then "  answer probabilities: \(probs(.answer_probabilities))" else empty end),
      "  evidence: \($manifest | length) item(s)"
        + (if ($manifest | length) > 0 then ": " + ([$manifest[] | "\(.source | flat) (sha256:\(.sha256), \(.bytes) bytes)"] | join("; ")) else "" end),
      (if .reason then "  reason: \(.reason | flat)" else empty end),
      "  record: \($record | flat)",
      (if .resolution then "  resolution: \(.resolution | flat)" else empty end),
      (if .resolution then "  command: bin/fm-send.sh \($task) --resolve-key \($key) \(.resolution | @sh)" else empty end)
    ' <<<"$result"
  fi
  exit 0
}

emit_error() {  # <reason>
  echo "decision-triage: error ($1)" >&2
  emit "$(jq -n --arg reason "$1" '{status: "error", reason: $reason}')"
}

# ---- 1. deterministic pre-gate, before any model call ---------------------------
HAYSTACK=$(jq -r '[.question, .accepted_intent, (.options | to_entries[] | .value)] | join("\n")' <<<"$SENT")
for entry in "${PREGATE[@]}"; do
  class=${entry%%$'\t'*}
  hit=$(printf '%s' "$HAYSTACK" | grep -Eio -m1 "${entry#*$'\t'}" 2>/dev/null) || hit=''
  [ -n "$hit" ] || continue
  emit "$(jq -n --arg class "$class" --arg hit "$hit" '{
    status: "escalate", class: $class, pregate: "matched \($class): \"\($hit)\"",
    reason: "policy pre-gate: \($class) decisions are the captain'"'"'s, never triaged here"}')"
done

# ---- 2. one POST, two Choice questions ------------------------------------------
command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
REQUEST=$(jq -n --arg model "$FM_JEV_MODEL" --arg task "$TASK" --argjson sent "$SENT" '
  {
    model: $model,
    state: {decision: ($sent + {task: $task})},
    questions: {
      class: {
        type: "choice",
        instructions: "Classify `decision`. Read `decision.question` against `decision.accepted_intent` and `decision.evidence`. Choose `routine` ONLY when the accepted intent and the evidence settle the question; otherwise choose the class that names who really owns it.",
        criteria: {
          routine: "The accepted intent and the supplied evidence settle this: an in-scope correction, a straight bug fix, completing an already-approved design, or a mechanical choice with one evidence-backed answer.",
          product: "A product, user-facing behaviour, or architecture call the accepted intent does not settle.",
          security: "It turns on credentials, secrets, permissions, sandboxing, or a security tradeoff.",
          schema: "It changes a data schema, wire format, on-disk format, or a compatibility surface others depend on.",
          destructive: "Acting on it destroys data or state.",
          irreversible: "It is hard or impossible to undo once acted on.",
          merge: "It authorises landing, merging, releasing, or publishing work.",
          ambiguous: "The evidence does not settle it, or the answer would materially expand what the project must deliver or maintain."
        }
      },
      answer: {
        type: "choice",
        instructions: "Which listed answer does `decision.evidence` and `decision.accepted_intent` support for `decision.question`? Choose `escalate` whenever the evidence does not clearly support exactly one of them.",
        criteria: (($sent.options | to_entries | map({key: .key, value: .value}) | from_entries)
          + {escalate: "No listed answer is settled by the evidence; a human must choose."})
      }
    }
  }') || emit_error "could not build the request"

HTTP=000 LAT_MS=null
fm_jev_post "$REQUEST" "$RESP_FILE" HTTP LAT_MS
[ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"

jq -e --argjson sent "$SENT" '
  def sane($a; $choices):
    ($a.choice | type) == "string" and
    ($choices | index($a.choice)) != null and
    ($a.confidence | type) == "number" and $a.confidence >= 0 and $a.confidence <= 1 and
    ($a.probabilities | type) == "object" and
    (($a.probabilities | keys | sort) == ($choices | sort)) and
    all($a.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    (($a.probabilities | [.[]] | add) as $t | $t >= 0.99 and $t <= 1.01);
  (["routine","product","security","schema","destructive","irreversible","merge","ambiguous"]) as $classes |
  (($sent.options | keys) + ["escalate"]) as $answers |
  sane(.answers.class; $classes) and sane(.answers.answer; $answers) and
  ((has("usage") | not) or
    ((.usage | type) == "object" and
     (.usage.input_tokens | type) == "number" and
     (.usage.output_tokens | type) == "number"))' "$RESP_FILE" >/dev/null 2>&1 \
  || emit_error "response is not a class and answer Choice pair"

# ---- 3. code decides ------------------------------------------------------------
RESULT=$(jq -n --arg floor "$FM_JEV_CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --argjson sent "$SENT" \
  --slurpfile resp "$RESP_FILE" '
  ($resp[0]) as $r | ($r.answers.class) as $c | ($r.answers.answer) as $a | ($floor | tonumber) as $floor |
  {
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    pregate: "clear",
    class: $c.choice, class_confidence: $c.confidence, class_probabilities: $c.probabilities,
    answer: $a.choice, answer_confidence: $a.confidence, answer_probabilities: $a.probabilities
  } as $ev |
  if $c.choice != "routine" and $c.confidence >= $floor then
    $ev + {status: "escalate", reason: "classified \($c.choice): the captain owns this decision"}
  elif $c.confidence < $floor then
    $ev + {status: "ambiguous", reason: "class confidence \($c.confidence) below floor \($floor)"}
  elif $a.choice == "escalate" then
    $ev + {status: "escalate", reason: "no listed answer is settled by the evidence"}
  elif $a.confidence < $floor then
    $ev + {status: "ambiguous", reason: "answer confidence \($a.confidence) below floor \($floor)"}
  else
    $ev + {status: "resolve", resolution: $sent.options[$a.choice]}
  end') || emit_error "resolution failed"

emit "$RESULT"
