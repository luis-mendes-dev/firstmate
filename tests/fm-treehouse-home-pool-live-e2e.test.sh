#!/usr/bin/env bash
# Live guard: the real treehouse must keep two firstmate homes' worktree
# allocations in their own clones.
#
# tests/fm-treehouse-home-pool.test.sh pins the logic portably - pool roots per
# home, the spawn's refusals - but the property that actually broke is
# treehouse's own: it keyed a pool by clone BASENAME plus repository identity, so
# two homes whose clones were both named projects/<name> shared one pool and were
# handed each other's worktrees. Only the installed binary can prove that an
# explicit per-home root closes it, and only for the version installed here, so
# this runs by default wherever treehouse is and names the version it checked.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-treehouse-lib.sh
. "$ROOT/bin/fm-treehouse-lib.sh"

fm_live_gate default-on FM_LIVE_TREEHOUSE_POOL treehouse

TMP_ROOT=$(fm_test_tmproot fm-treehouse-home-pool-live)
fm_git_identity

printf '# treehouse %s\n' "$(treehouse --version 2>&1 | head -1)"

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

IFS='|' read -r _ LIVE_A LIVE_B <<EOF
$(make_two_homes live)
EOF
mkdir -p "$TMP_ROOT/live/pools"
fm_treehouse_supports_root \
  || fail "installed treehouse has no --root (needs >=$FM_TREEHOUSE_MIN_ROOT_VERSION)"

live_acquire() {  # <home> -> worktree path
  local home=$1 root
  root=$(TREEHOUSE_ROOT="$TMP_ROOT/live/pools" fm_treehouse_home_pool_root "$home") || return 1
  mkdir -p "$root"
  ( cd "$home/projects/proj" &&
    treehouse get --root "$root" --no-fetch --lease --lease-holder live 2>/dev/null )
}

live_a=$(live_acquire "$LIVE_A") || fail "treehouse get failed for the first home"
live_b=$(live_acquire "$LIVE_B") || fail "treehouse get failed for the second home"
[ -n "$live_a" ] && [ -n "$live_b" ] || fail "treehouse reported no worktree path"

assert_not_equals "$live_a" "$live_b" \
  "two homes must not be handed the same worktree root"
common_a=$(git -C "$live_a" rev-parse --path-format=absolute --git-common-dir)
common_b=$(git -C "$live_b" rev-parse --path-format=absolute --git-common-dir)
assert_equals \
  "$(git -C "$LIVE_A/projects/proj" rev-parse --path-format=absolute --git-common-dir)" \
  "$common_a" "the first home's worktree must belong to its own clone"
assert_equals \
  "$(git -C "$LIVE_B/projects/proj" rev-parse --path-format=absolute --git-common-dir)" \
  "$common_b" "the second home's worktree must belong to its own clone"
assert_not_equals "$common_a" "$common_b" \
  "the two allocations must not share a clone identity"
pass "the real treehouse keeps two homes' allocations in separate clones"

# Returning each lease keeps the fixture from leaving pool state behind; a
# failure here is not the property under test, so it only warns.
for live in "$live_a" "$live_b"; do
  treehouse return --force "$live" >/dev/null 2>&1 ||
    printf 'warning: could not return %s\n' "$live" >&2
done

echo "# all fm-treehouse-home-pool-live-e2e tests passed"
