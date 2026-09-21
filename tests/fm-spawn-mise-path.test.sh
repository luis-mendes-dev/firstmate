#!/usr/bin/env bash
# tests/fm-spawn-mise-path.test.sh - a worker launched by a backend daemon must
# resolve the mise-managed toolchain (gh-axi, chrome-devtools-axi) even when the
# pane shell never ran the operator's login files.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the pane
# exports and the launch command under a synthetic pane environment whose PATH
# deliberately carries no mise directory, with the harness binary replaced by a
# probe that reports whether it could resolve gh-axi. What the probe prints is
# what a real agent, and the startup hooks it runs, would have resolved.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-mise-path)

# A mise data root shaped like a real one: `mise where node` answers with the
# versioned install directory, the toolchain lives in its bin, and shims/node is
# the symlink to the mise binary that the launch falls back to when mise itself
# is off PATH - the reduced-PATH case this covers.
#   make_mise_root <dir> [--no-shim] [--missing-install]
make_mise_root() {
  local root=$1 shim=1 install=1 arg
  shift
  for arg in "$@"; do
    case "$arg" in
      --no-shim) shim=0 ;;
      --missing-install) install=0 ;;
    esac
  done
  mkdir -p "$root/bin" "$root/shims"
  cat > "$root/bin/mise" <<SH
#!/bin/sh
[ "\${1:-}" = where ] && [ "\${2:-}" = node ] || exit 1
printf '%s\n' '$root/installs/node/22.23.2'
SH
  chmod +x "$root/bin/mise"
  [ "$shim" = 0 ] || ln -s "$root/bin/mise" "$root/shims/node"
  if [ "$install" = 1 ]; then
    mkdir -p "$root/installs/node/22.23.2/bin"
    cat > "$root/installs/node/22.23.2/bin/gh-axi" <<'SH'
#!/bin/sh
printf 'gh-axi\n'
SH
    chmod +x "$root/installs/node/22.23.2/bin/gh-axi"
  fi
  printf '%s\n' "$root"
}

# Replace the harness binary with a probe reporting the single environment fact
# under test, so executing the emitted launch answers "what would the agent have
# resolved" rather than "what does the command text look like".
install_tool_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
command -v gh-axi >/dev/null 2>&1 && printf 'resolved\n' || printf 'missing\n'
SH
  chmod +x "$1/$2"
}

# Replay the pane exports and the launch in a synthetic pane whose PATH holds no
# mise directory, which is exactly the daemon-started pane this fixes. The probe
# directory is passed separately so the harness binary stays resolvable while
# the toolchain does not.
#   emitted_launch_probe <fakebin> <launch-log> <pane-log>
emitted_launch_probe() {
  local fakebin=$1 launchlog=$2 panelog=$3 launch preamble
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog" || true)
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:/usr/bin:/bin" TERM=xterm \
    TMUX=synthetic-pane \
    /bin/sh -c "$preamble
$launch"
}

# run_spawn_case <name> <mise-root-or-empty> [make_mise_root flags...]
# Echoes "<fakebin>|<launch-log>|<pane-log>".
run_spawn_case() {
  local name=$1 mise=$2 case_dir home proj wt fakebin launchlog panelog out status
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name-a1"
  case " $* " in *' --allowlist '*) : > "$home/config/launch-env-allowlist" ;; esac
  [ -z "$mise" ] || make_mise_root "$mise" "$@" >/dev/null
  : > "$launchlog"
  : > "$panelog"
  # MISE_DATA_DIR is mise's own documented data root, so pinning it is how a
  # test supplies a toolchain without touching the developer's real one. An
  # empty value in the no-mise case still resolves under the throwaway HOME
  # fm_test_run_spawn pins, so nothing on this machine is discovered either way.
  out=$(MISE_DATA_DIR="${mise:-$case_dir/absent-mise}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$name-a1" "$proj" \
    --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "$name spawn should succeed: $out"
  printf '%s\n' "$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r FAKEBIN LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

test_pane_gains_the_mise_toolchain() {
  local seen gotmp path_line
  read_case "$(run_spawn_case mise-present "$TMP_ROOT/mise-present/mise")"
  # Ordering: the PATH append must ride the same pre-launch site as GOTMPDIR,
  # which is what makes it set before the agent process starts.
  gotmp=$(grep -n '^export GOTMPDIR=' "$PANE_LOG" | tail -1 | cut -d: -f1)
  path_line=$(grep -n '^export PATH=' "$PANE_LOG" | tail -1 | cut -d: -f1)
  [ -n "$gotmp" ] && [ -n "$path_line" ] \
    || fail "the pane log is missing the pre-launch toolchain export"
  [ "$path_line" -gt "$gotmp" ] \
    || fail "the toolchain export must ride the GOTMPDIR pre-launch site (gotmp=$gotmp path=$path_line)"
  install_tool_probe "$FAKEBIN" codex
  seen=$(emitted_launch_probe "$FAKEBIN" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "mise present: the emitted launch failed to run"
  assert_equals resolved "$seen" \
    "a worker launched into a pane with no mise directory on PATH must still resolve the mise-managed toolchain"
  pass "a worker launch appends the mise Node toolchain to its pane PATH"
}

# An enabled launch-env allowlist relaunches the agent under a cleared
# environment that keeps only Firstmate's own floor, so it is where a PATH the
# pane gained can silently be lost again.
test_allowlist_keeps_the_toolchain() {
  local seen launch
  read_case "$(run_spawn_case mise-allowlist "$TMP_ROOT/mise-allowlist/mise" --allowlist)"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '/usr/bin/env -i' \
    "an enabled allowlist should launch under a cleared environment"
  install_tool_probe "$FAKEBIN" codex
  seen=$(emitted_launch_probe "$FAKEBIN" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "allowlist enabled: the emitted launch failed to run"
  assert_equals resolved "$seen" \
    "a worker launched under the cleared allowlisted environment must still resolve the mise-managed toolchain"
  pass "an enabled launch-env allowlist carries the toolchain PATH through the cleared environment"
}

# The reduced PATH is the condition this exists for, so the fixture never puts
# mise on PATH: only the shims symlink can have supplied it above. Removing that
# symlink must lose the append, which is what proves the symlink carried it.
test_shim_fallback_is_what_resolves_mise() {
  local seen
  read_case "$(run_spawn_case mise-no-shim "$TMP_ROOT/mise-no-shim/mise" --no-shim)"
  grep -q '^export PATH=' "$PANE_LOG" \
    && fail "with mise off PATH and no shim symlink, nothing proves where the toolchain is"
  install_tool_probe "$FAKEBIN" codex
  seen=$(emitted_launch_probe "$FAKEBIN" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "mise unreachable: the emitted launch failed to run"
  assert_equals missing "$seen" \
    "an unreachable mise must leave the pane PATH alone rather than guessing a directory"
  pass "the append comes from mise's own shim symlink, not from a guessed path"
}

# An answer mise gives for a directory that is not there is unproven, so the
# launch must leave PATH untouched rather than append a nonexistent directory.
test_missing_install_directory_is_not_appended() {
  read_case "$(run_spawn_case mise-empty "$TMP_ROOT/mise-empty/mise" --missing-install)"
  grep -q '^export PATH=' "$PANE_LOG" \
    && fail "a mise answer naming a directory that does not exist must not reach the pane PATH"
  pass "an unprovable mise answer leaves the pane PATH unchanged"
}

test_no_mise_leaves_the_launch_unchanged() {
  read_case "$(run_spawn_case mise-absent '')"
  grep -q '^export PATH=' "$PANE_LOG" \
    && fail "a host with no mise must not receive a toolchain PATH export"
  pass "a host with no mise launches exactly as before"
}

test_pane_gains_the_mise_toolchain
test_allowlist_keeps_the_toolchain
test_shim_fallback_is_what_resolves_mise
test_missing_install_directory_is_not_appended
test_no_mise_leaves_the_launch_unchanged
