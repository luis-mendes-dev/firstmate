#!/usr/bin/env bash
# Regression tests for home-scoped Treehouse pool selection.
#
# Treehouse keys a pool by the acquiring checkout's basename plus a hash of the
# repository identity, so two firstmate homes that each cloned one origin to
# $FM_HOME/projects/<name> resolved to a single repository-global pool and were
# handed each other's worktrees - a copy whose Git common dir belongs to a
# foreign clone, which bin/fm-claude-trust.sh then refuses to register trust for.
#
# These cases prove the three layers that close it: two homes on the same
# repository derive different pool roots, a spawn tells treehouse which root to
# use and refuses outright when treehouse cannot be told, and a foreign clone's
# worktree is refused by the spawn's own isolation test even if one reaches it.
# tests/fm-treehouse-home-pool-live-e2e.test.sh proves the same isolation against
# the real treehouse, where the pool-key collision itself lives.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-home-pool)
fm_git_identity

# shellcheck source=bin/fm-treehouse-lib.sh
. "$ROOT/bin/fm-treehouse-lib.sh"

# Two homes, one origin, and the SAME clone basename in each - the shape that
# collided. Echoes "<origin>|<homeA>|<homeB>".
make_two_homes() {
  local name=$1 case_dir origin home
  case_dir="$TMP_ROOT/$name"
  origin="$case_dir/origin.git"
  mkdir -p "$case_dir/seed"
  fm_git_init_commit "$case_dir/seed"
  git clone --quiet --bare "$case_dir/seed" "$origin"
  for home in "$case_dir/homeA" "$case_dir/homeB"; do
    fm_test_spawn_home "$home" codex
    git clone --quiet "file://$origin" "$home/projects/proj"
  done
  printf '%s|%s|%s\n' "$origin" "$case_dir/homeA" "$case_dir/homeB"
}

# --- pool roots are per home ------------------------------------------------

IFS='|' read -r _ ROOT_A ROOT_B <<EOF
$(make_two_homes roots)
EOF

mkdir -p "$TMP_ROOT/roots/pools"
root_a=$(TREEHOUSE_ROOT="$TMP_ROOT/roots/pools" fm_treehouse_home_pool_root "$ROOT_A")
root_b=$(TREEHOUSE_ROOT="$TMP_ROOT/roots/pools" fm_treehouse_home_pool_root "$ROOT_B")
assert_not_equals "$root_a" "$root_b" \
  "two homes on one repository must not share a pool root"
pass "two homes on the same repository derive different pool roots"

again=$(TREEHOUSE_ROOT="$TMP_ROOT/roots/pools" fm_treehouse_home_pool_root "$ROOT_A")
assert_equals "$root_a" "$again" "a home's pool root must be stable"
pass "a home's pool root is stable across calls"

# The root must sit outside the home: a home is itself a git worktree, and pools
# under it would dirty the copy teardown's landed-work checks read.
case "$root_a" in
  "$ROOT_A"/*) fail "pool root $root_a is inside the home $ROOT_A" ;;
esac
pass "a home's pool root is outside the home itself"

# --- the spawn tells treehouse which root to use ----------------------------

IFS='|' read -r _ SPAWN_HOME SPAWN_OTHER <<EOF
$(make_two_homes spawn)
EOF

spawn_case() {  # <home> <task-id> <pane-path>
  local home=$1 id=$2 pane=$3 fakebin
  fakebin=$(make_spawn_fakebin "$home/fake")
  fm_test_spawn_brief "$home" "$id"
  FM_FAKE_PANE_LOG="$home/pane.log" TREEHOUSE_ROOT="$TMP_ROOT/spawn/pools" \
    fm_test_run_spawn "$home" "$pane" "$fakebin" \
    "$id" "$home/projects/proj" --mode direct-PR --yolo off
}

# A pool slot of this home's own clone, which is what a scoped treehouse get
# would have produced.
mkdir -p "$TMP_ROOT/spawn/pools"
OWN_POOL_ROOT=$(TREEHOUSE_ROOT="$TMP_ROOT/spawn/pools" fm_treehouse_home_pool_root "$SPAWN_HOME")
OWN_SLOT="$OWN_POOL_ROOT/.treehouse/proj-test/1/proj"
mkdir -p "$(dirname "$(dirname "$OWN_SLOT")")"
printf '{"worktrees":[]}\n' > "$(dirname "$(dirname "$OWN_SLOT")")/treehouse-state.json"
git -C "$SPAWN_HOME/projects/proj" worktree add --quiet --detach "$OWN_SLOT" HEAD

out=$(spawn_case "$SPAWN_HOME" own-slot "$OWN_SLOT" 2>&1) || {
  printf '%s\n' "$out" >&2
  fail "spawn into this home's own pool slot must succeed"
}
assert_grep "treehouse get --root '$OWN_POOL_ROOT'" "$SPAWN_HOME/pane.log" \
  "the pane must be told this home's own pool root"
pass "a spawn sends treehouse get with this home's pool root"

# --- a worktree of another clone is refused ---------------------------------

# The exact copy the repository-global pool used to hand over: a real, clean,
# isolated pool slot - of the OTHER home's clone of the same origin.
FOREIGN_SLOT="$TMP_ROOT/spawn/foreign/1/proj"
mkdir -p "$TMP_ROOT/spawn/foreign"
printf '{"worktrees":[]}\n' > "$TMP_ROOT/spawn/foreign/treehouse-state.json"
git -C "$SPAWN_OTHER/projects/proj" worktree add --quiet --detach "$FOREIGN_SLOT" HEAD

rm -f "$SPAWN_HOME/pane.log"
out=$(spawn_case "$SPAWN_HOME" foreign-slot "$FOREIGN_SLOT" 2>&1) && {
  printf '%s\n' "$out" >&2
  fail "spawn must refuse a worktree belonging to another clone"
}
assert_contains "$out" "belongs to a different clone" \
  "the refusal must name the foreign clone as the reason"
assert_absent "$SPAWN_HOME/state/foreign-slot.meta" \
  "a refused spawn must record no task metadata"
pass "a worktree of another clone of the same repository is refused"

# The divergence the case rests on: that slot really is a valid isolated
# worktree, so it is rejected for its clone identity and nothing else.
foreign_common=$(git -C "$FOREIGN_SLOT" rev-parse --path-format=absolute --git-common-dir)
own_common=$(git -C "$SPAWN_HOME/projects/proj" rev-parse --path-format=absolute --git-common-dir)
assert_not_equals "$foreign_common" "$own_common" \
  "the refused slot must differ from this home's clone only in common git dir"
assert_equals "$FOREIGN_SLOT" "$(git -C "$FOREIGN_SLOT" rev-parse --show-toplevel)" \
  "the refused slot must be a worktree root, not a subdirectory"
pass "the refused slot is otherwise a valid isolated worktree"

# --- a treehouse that cannot be given a root refuses the spawn --------------

IFS='|' read -r _ NOROOT_HOME _ <<EOF
$(make_two_homes noroot)
EOF
noroot_bin=$(make_spawn_fakebin "$NOROOT_HOME/fake")
cat > "$noroot_bin/treehouse" <<'SH'
#!/usr/bin/env bash
# A pre-2.2.0 treehouse: get --help carries --lease but no --root.
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf 'Flags:\n      --lease   Durably lease a worktree\n'
  exit 0
fi
exit 0
SH
chmod +x "$noroot_bin/treehouse"
fm_test_spawn_brief "$NOROOT_HOME" task-1
out=$(TREEHOUSE_ROOT="$TMP_ROOT/noroot/pools" fm_test_run_spawn \
  "$NOROOT_HOME" "$NOROOT_HOME/projects/proj" "$noroot_bin" \
  task-1 "$NOROOT_HOME/projects/proj" --mode direct-PR --yolo off 2>&1) && {
  printf '%s\n' "$out" >&2
  fail "spawn must refuse when treehouse cannot be given a pool root"
}
assert_contains "$out" "explicit pool root" \
  "the refusal must name the missing pool-root capability"
assert_absent "$NOROOT_HOME/state/task-1.meta" \
  "a refused spawn must record no task metadata"
pass "a treehouse without --root refuses the spawn instead of using the shared pool"

# --- legacy repository-global slots are reported, never touched -------------

IFS='|' read -r _ LEGACY_HOME LEGACY_OTHER <<EOF
$(make_two_homes legacy)
EOF
mkdir -p "$TMP_ROOT/legacy/pools"
LEGACY_POOL="$TMP_ROOT/legacy/shared-pool"
mkdir -p "$LEGACY_POOL"
printf '{"worktrees":[]}\n' > "$LEGACY_POOL/treehouse-state.json"
git -C "$LEGACY_HOME/projects/proj" worktree add --quiet --detach "$LEGACY_POOL/1/proj" HEAD
git -C "$LEGACY_OTHER/projects/proj" worktree add --quiet --detach "$LEGACY_POOL/2/proj" HEAD
printf 'task=old-task\nhome=%s\n' "$LEGACY_HOME" > "$LEGACY_POOL/1/.fm-slot-owner"

slots=$(TREEHOUSE_ROOT="$TMP_ROOT/legacy/pools" \
  fm_treehouse_legacy_pool_slots "$LEGACY_HOME/projects/proj" "$LEGACY_HOME")
assert_contains "$slots" "$LEGACY_POOL/1/proj	old-task" \
  "this home's legacy slot must be reported with its recorded claim"
assert_not_contains "$slots" "$LEGACY_POOL/2/proj" \
  "another home's legacy slot must never be reported here"
pass "legacy repository-global slots are reported for this home only"

echo "# all fm-treehouse-home-pool tests passed"
