#!/usr/bin/env bash
# fm-jev-lib.sh - the single owner of firstmate's authenticated transport to
# typesafe.ai's System One model (Jev).
#
# Sourced, never executed. It exists so every Jev caller shares ONE copy of the
# opt-in gate, the fixed endpoint/model/timeout/floor constants, and the
# secret-handling boundary, instead of each caller re-deriving them and drifting.
#
# THE SECRET BOUNDARY, which every caller must keep:
#   The key lives in ONE non-exported shell variable (FM_JEV_KEY) and reaches
#   curl as a header read from a file descriptor, never on argv. Nothing here
#   prints, logs, or writes it.
#   A caller that accepts the key from its own environment MUST capture it into
#   FM_JEV_KEY and unset TYPESAFE_API_KEY in its FIRST lines, before sourcing
#   anything, because a source line can run an external command that would
#   otherwise inherit the secret. This library cannot do that for the caller:
#   by the time it is sourced, the caller has already reached that point.
#
# Functions:
#   fm_jev_gate <fm-home>
#     0 when FM_JEV_KEY holds a key - either the one the caller captured from
#     the environment, or a TYPESAFE_API_KEY= line from <fm-home>/.env read with
#     the same accessor Relay uses (fmx_env_get). The environment wins.
#     1 when no key resolved, which means the calling tool is OFF: the caller
#     prints its own one-line stderr notice and exits 0 without a network call.
#   fm_jev_post <request-json> <response-file> <code-var> <latency-var>
#     One POST to $FM_JEV_BASE/v1/systemone. Assigns the HTTP status code (000
#     for a transport failure) and the elapsed milliseconds into the two named
#     caller variables rather than printing them, so the call runs in the
#     caller's own shell and both facts survive. The caller checks for curl
#     first and owns its own error vocabulary.
#
# docs/configuration.md "Typed dispatch resolution" and "Decision triage" own
# the operator contracts of the two tools built on this transport.

FM_JEV_BASE=${FM_JEV_BASE:-https://api.typesafe.ai}
FM_JEV_MODEL=${FM_JEV_MODEL:-jev-latest}
FM_JEV_TIMEOUT=${FM_JEV_TIMEOUT:-5}
# Confidence at or above which a Jev answer may be acted on without a human.
FM_JEV_CONFIDENCE_FLOOR=${FM_JEV_CONFIDENCE_FLOOR:-0.6}
FM_JEV_KEY=${FM_JEV_KEY:-}
export -n FM_JEV_KEY 2>/dev/null || true

_fm_jev_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$_fm_jev_lib_dir/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$_fm_jev_lib_dir/fm-timing-lib.sh"
unset _fm_jev_lib_dir

fm_jev_gate() {  # <fm-home>
  if [ -z "${FM_JEV_KEY:-}" ]; then
    FM_JEV_KEY=$(fmx_env_get TYPESAFE_API_KEY "$1/.env")
  fi
  [ -n "${FM_JEV_KEY:-}" ]
}

fm_jev_post() {  # <request-json> <response-file> <code-var> <latency-var>
  local body=$1 out=$2 __code_var=$3 __lat_var=$4 code t0 t1
  t0=$(fm_timing_now_ms)
  code=$(printf '%s' "$body" | curl -sS --max-time "$FM_JEV_TIMEOUT" -o "$out" -w '%{http_code}' \
    -X POST "$FM_JEV_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$FM_JEV_KEY") \
    --data-binary @- 2>/dev/null) || code=000
  t1=$(fm_timing_now_ms)
  printf -v "$__code_var" '%s' "$code"
  printf -v "$__lat_var" '%s' "$(( t1 - t0 ))"
}
