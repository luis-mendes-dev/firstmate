#!/usr/bin/env bash
# Behavior tests for bin/fm-decision-triage.sh.
#
# Drives the public argv, stdin, and environment interface with a fake curl on
# PATH that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, then answers with a canned typesafe.ai response.
# No case touches the network, and the absent-key, pre-gate, and boundary cases
# prove the tool makes no call at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-decision-triage.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-triage)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
RESPONSE="$TMP_ROOT/response.json"
DECISION="$TMP_ROOT/decision.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/data/t1" "$LOG" "$NO_CURL_BIN"
for command_name in awk bash cat chmod cp cut date dirname grep head jq mkdir mktemp rm sed shasum tr wc; do
  target=$(command -v "$command_name" 2>/dev/null) || continue
  ln -s "$target" "$NO_CURL_BIN/$command_name"
done

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${FM_JEV_KEY+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"

# write_response <class> <class-confidence> <answer> <answer-confidence>
write_response() {
  cat > "$RESPONSE" <<JSON
{ "model": "jev-1.13.0",
  "answers": {
    "class": { "type": "choice", "choice": "$1", "confidence": $2, "probabilities": {
      "routine": 0.86, "product": 0.02, "security": 0.02, "schema": 0.02,
      "destructive": 0.02, "irreversible": 0.02, "merge": 0.02, "ambiguous": 0.02 } },
    "answer": { "type": "choice", "choice": "$3", "confidence": $4, "probabilities": {
      "fix": 0.90, "accept": 0.05, "escalate": 0.05 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}

# write_decision <question> [extra jq filter]
write_decision() {
  local question=$1 filter=${2:-.}
  jq -n --arg q "$question" '{
    task: "t1", key: "nm-42-review", question: $q,
    options: [
      {id: "fix", answer: "Fix finding 3: the loop must include the final row."},
      {id: "accept", answer: "Accept the current behaviour."}
    ],
    intent: "Make the pager emit every row exactly once.",
    evidence: [{source: "bin/pager.sh:40", text: "while i < n - 1 do"}]
  }' | jq "$filter" > "$DECISION"
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

KEY='test-key-9f1c2d3e-never-on-argv'
RECORD="$HOME_DIR/data/t1/triage-nm-42-review.md"
code='' out='' err=''

# --- absent key: off, silent on stdout, no network --------------------------
reset_log
write_response routine 0.91 fix 0.88
write_decision "Finding 3 says the loop drops the last row. Fix it or accept as-is?"
run code out err "$DECISION"
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'decision-triage: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$RECORD" "absent key writes no record"
pass "absent key is off: one stderr line, exit 0, no network call"

# --- .env key, and the environment wins over it ------------------------------
printf '%s\n' '# local secrets' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
run code out err "$DECISION"
assert_contains "$out" '  status: resolve' ".env key turns the tool on"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" ".env key reaches curl on the fd header"
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$DECISION"
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env" "$RECORD"
pass "TYPESAFE_API_KEY= in .env activates the tool; the environment wins over it"

# --- resolve: request shape, secret handling, durable record, send command ---
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
expect_code 0 "$code" "resolve exits 0"
assert_contains "$out" 'decision-triage:' "TOON block header"
assert_contains "$out" '  status: resolve' "resolve status"
assert_contains "$out" '  task: t1   key: nm-42-review' "task and key line"
assert_contains "$out" '  class: routine   confidence: 0.91' "class and its confidence"
assert_contains "$out" '  answer: fix   confidence: 0.88' "answer and its confidence"
assert_contains "$out" '  answer probabilities: fix=0.90 accept=0.05 escalate=0.05' "answer probabilities are published"
assert_contains "$out" '  resolution: Fix finding 3: the loop must include the final row.' "the resolution is the caller's own option text"
assert_contains "$out" "  command: bin/fm-send.sh t1 --resolve-key nm-42-review 'Fix finding 3: the loop must include the final row.'" \
  "the answer routes through fm-send --resolve-key, quoted for the shell"
assert_contains "$out" '  evidence: 2 item(s): bin/pager.sh:40 (sha256:' "the evidence manifest names each source with its digest"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the request uses the fixed typesafe.ai endpoint"
assert_contains "$argv" $'--max-time\n5' "the request uses the shared five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals 'curl:clean' "$(cat "$LOG/child-env")" "the API key is absent from every child environment"
body=$(cat "$LOG/body")
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "default model is jev-latest"
assert_equals '["answer","class"]' "$(jq -c '.questions | keys' <<<"$body")" "one POST asks the class and answer Choices"
assert_equals '["accept","escalate","fix"]' "$(jq -c '.questions.answer.criteria | keys' <<<"$body")" \
  "the answer options are the caller's own ids plus the fixed escalate option"
assert_equals 't1' "$(jq -r .state.decision.task <<<"$body")" "the task id rides in the state"
assert_contains "$(jq -r .state.decision.accepted_intent <<<"$body")" 'every row exactly once' "the accepted intent rides in the state"
assert_contains "$(jq -r '.state.decision.evidence[0].text' <<<"$body")" 'while i < n - 1 do' "caller evidence rides in the state"
pass "resolve: fixed endpoint and model, both Choices, evidence in state, key only on the fd header"

# --- the durable record ------------------------------------------------------
record=$(cat "$RECORD")
assert_contains "$record" 'status=resolve' "the record states the outcome"
assert_contains "$record" '- key: nm-42-review' "the record names the decision key"
assert_contains "$record" '- pre-gate: clear' "the record states the deterministic pre-gate result"
assert_contains "$record" '- class: routine (confidence 0.91)' "the record keeps the classification rationale"
assert_contains "$record" '- model: jev-1.13.0, latency ' "the record keeps the model provenance"
assert_contains "$record" '  - bin/pager.sh:40  sha256:' "the record keeps a digest per evidence item"
assert_contains "$record" '- resolution: Fix finding 3:' "the record keeps the resolution text"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
assert_equals 2 "$(grep -c '^## ' "$RECORD")" "a second run appends a second block instead of overwriting"
rm -f "$RECORD"
pass "every completed triage appends dated rationale and provenance to data/<task>/triage-<key>.md"

# --- the deterministic pre-gate escalates with no model call -----------------
for probe in \
  'merge|Checks are green. Should I merge the PR now?' \
  'destructive|The fixture is stale: is it right to drop table sessions first?' \
  'irreversible|This needs a data migration before the new column is readable.' \
  'security|Should the helper read the api key from the environment or a private key file?' \
  'schema|Should the record gain a field, or is that a breaking change for readers?' \
  'product|Is this a product decision about what the users see, or just a bug?'
do
  reset_log
  expected=${probe%%|*}
  write_decision "${probe#*|}"
  TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
  expect_code 0 "$code" "pre-gate $expected exits 0"
  assert_contains "$out" '  status: escalate' "pre-gate $expected escalates"
  assert_contains "$out" "  class: $expected" "pre-gate names the $expected class"
  assert_contains "$out" "  pre-gate: matched $expected: " "pre-gate publishes the text it matched"
  assert_not_contains "$out" '  model:' "pre-gate $expected reports no model call"
  assert_absent "$LOG/argv" "pre-gate $expected never calls curl"
  assert_contains "$(cat "$RECORD")" "- pre-gate: matched $expected" "pre-gate $expected is recorded"
  rm -f "$RECORD"
done
pass "the pre-gate escalates merge, destructive, irreversible, security, schema, and product decisions before any model call"

# --- the pre-gate can only escalate, never clear ------------------------------
reset_log
write_decision "Finding 3 says the loop drops the last row. Fix it or accept as-is?"
write_response product 0.93 fix 0.95
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
assert_contains "$out" '  status: escalate' "a non-routine class escalates even with a confident answer"
assert_contains "$out" '  reason: classified product: the captain owns this decision' "the reason names the class"
assert_not_contains "$out" '  resolution:' "an escalated decision publishes no resolution"
assert_not_contains "$out" '  command:' "an escalated decision publishes no send command"
rm -f "$RECORD"
reset_log
write_response routine 0.91 escalate 0.97
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
assert_contains "$out" '  status: escalate' "the model's own escalate answer escalates"
assert_contains "$out" '  reason: no listed answer is settled by the evidence' "the reason names the unsupported answer"
rm -f "$RECORD"
pass "a non-routine class or an escalate answer escalates and publishes no command"

# --- the confidence floor ------------------------------------------------------
reset_log
write_response routine 0.44 fix 0.95
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
assert_contains "$out" '  status: ambiguous' "a class below the floor is ambiguous"
assert_contains "$out" '  reason: class confidence 0.44 below floor 0.6' "the reason names the floor"
rm -f "$RECORD"
reset_log
write_response routine 0.91 fix 0.41
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
assert_contains "$out" '  status: ambiguous' "an answer below the floor is ambiguous"
assert_contains "$out" '  reason: answer confidence 0.41 below floor 0.6' "the reason names the answer floor"
assert_not_contains "$out" '  command:' "an ambiguous decision publishes no send command"
rm -f "$RECORD"
pass "either confidence below the shared floor is ambiguous, never a resolution"

# --- evidence boundaries: refused before any network call ---------------------
reset_log
write_decision "Which retry budget should the poll use?" \
  '.evidence += [{source: ".env", text: "TYPESAFE_API_KEY=sk-live-0123456789abcdef"}]'
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
expect_code 2 "$code" "evidence carrying a secret exits 2"
assert_contains "$err" 'matches a secret shape; nothing was sent' "the refusal says nothing was sent"
assert_absent "$LOG/argv" "evidence carrying a secret never reaches curl"
reset_log
write_decision "Which retry budget should the poll use?" \
  '.evidence += [{source: "notes", text: "password: hunter2-hunter2"}]'
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
expect_code 2 "$code" "a bare credential assignment in evidence exits 2"
assert_absent "$LOG/argv" "a bare credential assignment never reaches curl"
reset_log
write_decision "Which retry budget should the poll use?"
FM_TRIAGE_EVIDENCE_MAX=64 TYPESAFE_API_KEY=$KEY \
  run code out err "$DECISION"
expect_code 2 "$code" "evidence over the cap exits 2"
assert_contains "$err" 'over the 64 byte cap (FM_TRIAGE_EVIDENCE_MAX)' "the refusal names the cap and its override"
assert_absent "$LOG/argv" "evidence over the cap never reaches curl"
assert_absent "$RECORD" "a refused decision writes no record"
pass "secret-shaped and oversized evidence are refused with exit 2 before any network call"

# --- repository evidence: the brief supplies the accepted intent ---------------
cat > "$HOME_DIR/data/t1/brief.md" <<'MD'
# Task
## Captain's intent
Make the pager emit every row exactly once.

## Firstmate spec
SECRET-SPEC-TEXT that is firstmate's build instruction, not the captain's ask.
MD
reset_log
write_response routine 0.91 fix 0.88
write_decision "Finding 3 says the loop drops the last row. Fix it or accept as-is?" 'del(.intent)'
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
assert_contains "$out" '  status: resolve' "a decision with no caller intent still resolves"
body=$(cat "$LOG/body")
assert_contains "$(jq -r .state.decision.accepted_intent <<<"$body")" 'every row exactly once' \
  "the brief's Captain's intent subsection becomes the accepted contract"
assert_not_contains "$body" 'SECRET-SPEC-TEXT' "the firstmate spec is not sent as captain intent"
assert_contains "$out" "  evidence: 2 item(s)" "the brief-sourced intent is listed as evidence"
assert_contains "$(cat "$RECORD")" 'brief.md  sha256:' "the record names the brief as the intent's provenance"
rm -f "$RECORD" "$HOME_DIR/data/t1/brief.md"
pass "with no caller intent the task brief's Captain's intent is read as repository evidence"

# --- stdin and --json ----------------------------------------------------------
reset_log
write_decision "Finding 3 says the loop drops the last row. Fix it or accept as-is?"
_out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=$KEY "$TOOL" - --json < "$DECISION" 2>/dev/null)
assert_equals 'resolve' "$(jq -r .status <<<"$_out")" "--json emits the machine-readable result from a stdin document"
assert_equals 'routine' "$(jq -r .class <<<"$_out")" "--json carries the class"
assert_equals "$RECORD" "$(jq -r .record <<<"$_out")" "--json names the durable record"
assert_equals 'bin/pager.sh:40' "$(jq -r '.evidence[0].source' <<<"$_out")" "--json carries the evidence manifest"
rm -f "$RECORD"
pass "the decision document is accepted on stdin and --json emits the machine-readable result"

# --- API, transport, and response failures are error outcomes with exit 0 ------
reset_log
FAKE_CURL_HTTP=500 TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
expect_code 0 "$code" "http 500 exits 0"
assert_contains "$out" '  status: error' "http 500 is an error outcome"
assert_contains "$out" '  reason: http 500' "the reason names the status code"
assert_absent "$RECORD" "an error outcome writes no record"
reset_log
FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
assert_contains "$out" '  status: error' "a transport failure is an error outcome"
reset_log
printf '%s\n' '{"model":"jev-1.13.0","answers":{"class":{"type":"choice","choice":"routine","confidence":2}}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
expect_code 0 "$code" "a malformed response exits 0"
assert_contains "$out" '  reason: response is not a class and answer Choice pair' "a malformed response is rejected by name"
write_response routine 0.91 fix 0.88
reset_log
_out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=$KEY "$TOOL" "$DECISION" 2>/dev/null)
assert_contains "$_out" '  reason: curl not installed' "missing curl is a structured error outcome"
rm -f "$RECORD"
pass "API, transport, response, and missing-curl failures are error outcomes with exit 0 and no record"

# --- input errors exit 2 before any network call -------------------------------
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$TMP_ROOT/absent.json"
expect_code 2 "$code" "an unreadable decision document exits 2"
assert_contains "$err" 'decision document not readable' "the unreadable document is named"
printf 'not json\n' > "$TMP_ROOT/bad.json"
TYPESAFE_API_KEY=$KEY run code out err "$TMP_ROOT/bad.json"
expect_code 2 "$code" "a non-JSON document exits 2"
assert_contains "$err" 'malformed decision document (not JSON)' "non-JSON is reported as such"
for bad in \
  'del(.task)|task must be a task id' \
  '.key = "has spaces"|key must be a decision key' \
  '.task = ".."|task must be a task id' \
  'del(.question)|question must be the non-empty decision text' \
  '.options = []|options must be a non-empty array' \
  '.options = [{id: "fix"}]|each option needs a non-empty id and answer' \
  '.options[0].id = "Fix It"|each option id must match' \
  '.options += [{id: "escalate", answer: "x"}]|"escalate" is reserved' \
  '.options += [{id: "fix", answer: "again"}]|option ids must be unique' \
  '.evidence = [{source: "x"}]|each evidence item needs a non-empty source and text'
do
  reset_log
  write_decision "Finding 3 says the loop drops the last row." "${bad%%|*}"
  TYPESAFE_API_KEY=$KEY run code out err "$DECISION"
  expect_code 2 "$code" "invalid input (${bad%%|*}) exits 2"
  assert_contains "$err" "${bad#*|}" "invalid input (${bad%%|*}) is named"
  assert_absent "$LOG/argv" "invalid input (${bad%%|*}) never calls curl"
done
assert_absent "$RECORD" "an invalid document writes no record"
pass "usage and input errors exit 2 before any network call"

printf '# all fm-decision-triage tests passed\n'
