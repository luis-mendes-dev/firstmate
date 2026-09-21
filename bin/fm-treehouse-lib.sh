#!/usr/bin/env bash
# Treehouse pool selection and slot ownership: which pool a Firstmate home
# allocates from, whether the installed Treehouse can be told, and which task
# owns a slot once it has one. The lock that serializes allocation and return
# stays in bin/fm-wake-lib.sh, which anchors it in the root home's state
# directory.
#
# Deliberately free of source-time side effects (no state directory, no config
# read), because bin/fm-bootstrap.sh sources it from its read-only detect phase.
# Its consumers - bin/fm-spawn.sh, bin/fm-teardown.sh, bin/fm-home-seed.sh - each
# source it beside fm-wake-lib.sh rather than through it, so that library stays
# usable on its own as the queue-and-lock primitive minimal recovery fixtures and
# remote installs carry.
#
# WHY A HOME-SCOPED ROOT EXISTS. Treehouse keys a pool by the acquiring
# checkout's DIRECTORY BASENAME plus a hash of the repository identity -
# <root>/.treehouse/<basename>-<hash>/<slot>/<repo> - and neither component
# distinguishes two clones of one origin sitting at different paths. Every
# Firstmate home clones a project to $FM_HOME/projects/<name>, so two homes
# working on the same repository resolve to the same basename, the same origin
# hash, and therefore ONE shared pool. Each slot in it is a linked worktree of
# whichever home's clone happened to create it, and Treehouse hands an idle slot
# to a later `get` from the other home unchanged. That home then receives a
# worktree whose Git common dir belongs to a foreign clone, and nothing
# downstream can recover: bin/fm-claude-trust.sh's structural scope test refuses
# to register workspace trust for a copy that is not a worktree of the spawning
# project, so the worker wedges on a dialog Firstmate cannot answer instead of
# reaching its brief.
#
# Scoping the pool root to the acquiring home makes that collision impossible
# rather than merely detected: a home's `get` can only ever see slots it created
# itself. Project clone sharing is untouched - the scope is the HOME, not the
# clone, so two homes may still point at one shared clone and each keeps its own
# pool of worktrees on it, exactly as Git allows.

# The Treehouse release that introduced --root/TREEHOUSE_ROOT, and with it the
# ability to place a pool anywhere but the one repository-global default.
# shellcheck disable=SC2034 # Read by the sourcing caller's refusal messages.
FM_TREEHOUSE_MIN_ROOT_VERSION=2.2.0

# True when the installed Treehouse honors an explicit pool root.
#
# A capability probe of `get --help` rather than a version parse, matching the
# --lease probe this gate sits beside in bin/fm-bootstrap.sh: a vendored or
# development build that carries the flag passes, and one that does not is
# refused whatever it calls itself.
fm_treehouse_supports_root() {
  command -v treehouse >/dev/null 2>&1 || return 1
  treehouse get --help 2>&1 |
    grep -Eq '(^|[^[:alnum:]_-])--root([^[:alnum:]_-]|$)'
}

# The Treehouse pool root owned by one Firstmate home. Defaults to $FM_HOME.
#
# Placed beside Treehouse's own default root (its --root default is $HOME), never
# inside the home: a home is itself a Git worktree, `.treehouse/` is in no
# ignore list, and pools under it would dirty the very copy teardown's
# landed-work checks read. An operator TREEHOUSE_ROOT is honored as the base, so
# a host that keeps worktrees off the home volume keeps doing so.
#
# The identity is the home's resolved path, so the derivation is stable for as
# long as the home is, and a moved home simply starts a fresh pool rather than
# inheriting another home's slots. The basename prefix is cosmetic - it is what
# makes `ls` of the base readable - and the hash carries the whole identity.
fm_treehouse_home_pool_root() {  # [home]
  local home=${1:-$FM_HOME} base slug hash
  [ -n "$home" ] || return 1
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  base=${TREEHOUSE_ROOT:-$HOME}
  case $base in /*) ;; *) return 1 ;; esac
  # Resolved when it exists, so the printed root compares equal to a `pwd -P`
  # reading of a worktree under it. A base that does not exist yet stays literal
  # rather than failing or being created: this stays a pure path helper, because
  # bin/fm-bootstrap.sh's read-only detect phase calls it.
  if [ -d "$base" ]; then
    base=$(CDPATH='' cd -- "$base" 2>/dev/null && pwd -P) || return 1
  fi
  hash=$(printf '%s' "$home" | git hash-object --stdin 2>/dev/null) || return 1
  [ ${#hash} -ge 12 ] || return 1
  slug=$(basename -- "$home")
  slug=$(printf '%s' "$slug" | tr -c '[:alnum:]._-' '-')
  [ -n "$slug" ] || slug=home
  printf '%s/.fm-treehouse/%s-%s\n' "$base" "$slug" "${hash:0:12}"
}

# Pooled worktrees of <project> that sit OUTSIDE this home's own pool root: the
# slots a legacy repository-global pool holds for this clone.
#
# One line per slot, "<worktree><TAB><claim>", where <claim> is the task id
# Firstmate recorded for it or "unclaimed". Prints nothing and succeeds when
# there are none.
#
# Git is the only authority consulted for membership, so a slot of this clone is
# reported whatever pool it was filed under and another home's slots never are.
# That also keeps this free of any second copy of Treehouse's pool-key
# derivation, which is exactly the fragile assumption the collision came from.
fm_treehouse_legacy_pool_slots() {  # <project> [home]
  local project=$1 home=${2:-$FM_HOME} root prefix line worktree claim
  [ -d "$project" ] || return 1
  root=$(fm_treehouse_home_pool_root "$home") || return 1
  prefix="$root/"
  while IFS= read -r line; do
    case "$line" in worktree\ *) worktree=${line#worktree } ;; *) continue ;; esac
    worktree=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || continue
    case "$worktree" in "$prefix"*) continue ;; esac
    # Only a managed pool slot, never a hand-made worktree of the same clone.
    fm_treehouse_pool_slot "$project" "$worktree" || continue
    claim=unclaimed
    fm_treehouse_slot_owner_state "$worktree" ''
    [ -z "$FM_TREEHOUSE_SLOT_OWNER_ID" ] || claim=$FM_TREEHOUSE_SLOT_OWNER_ID
    printf '%s\t%s\n' "$worktree" "$claim"
  done < <(git -C "$project" worktree list --porcelain 2>/dev/null)
}

# A Treehouse slot has the managed pool's fixed <pool>/<slot>/<repo> layout.
# Require both its pool state and the same Git common directory as the recorded
# project; an ordinary linked worktree is not evidence that Treehouse owns it.
fm_treehouse_pool_slot() {  # <project-dir> <worktree>
  local project=$1 worktree=$2 slot pool state project_common slot_common
  [ -d "$project" ] && [ -d "$worktree" ] || return 1
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 1
  pool=$(dirname "$(dirname "$slot")")
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  slot_common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  project_common=$(CDPATH='' cd -- "$project_common" 2>/dev/null && pwd -P) || return 1
  slot_common=$(CDPATH='' cd -- "$slot_common" 2>/dev/null && pwd -P) || return 1
  [ "$project_common" = "$slot_common" ]
}

# Slot-owner claim: which task a Treehouse pool slot currently belongs to.
#
# Treehouse can record ownership durably: `treehouse get --lease --lease-holder`
# reserves a slot under a label until `treehouse return --if-lease-holder`
# releases it, and Firstmate uses exactly that for secondmate homes
# (bin/fm-home-seed.sh). Crewmate spawns do not take that path: they acquire
# their slot through the interactive pane-driven `treehouse get`, whose state
# entry is a live process lease (owner_pid plus owner_started_at, and `treehouse
# status` reports in-use from the processes actually running under the path).
# That answers "is anything running here", never "which task owns this", and it
# is released by the very event that makes a task record stale - the worker
# exiting - so a slot whose lease has lapsed reads identical whether it is still
# this task's or has since been handed to another one. Firstmate therefore keeps
# its own claim on top: one file naming the task that took the slot, written by
# bin/fm-spawn.sh under the same project lock that allocates the slot and
# released by bin/fm-teardown.sh when the slot goes back to the pool. Moving
# crewmate spawns onto the durable lease is separate follow-up work.
#
# The claim lives at <pool>/<slot>/.fm-slot-owner - a sibling of the repo
# checkout rather than a file inside it - so claiming a slot can never dirty the
# copy teardown's landed-work checks inspect, and a returned slot carries no
# untracked leftover from it.
fm_treehouse_slot_owner_marker() {  # <worktree>
  local worktree=$1 slot
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 1
  printf '%s/.fm-slot-owner\n' "$(dirname "$slot")"
}

# Claim a pool slot for a task, replacing whatever the previous holder left.
# The rename is atomic, so a reader either sees the old claim or the new one.
fm_treehouse_slot_owner_claim() {  # <worktree> <task-id> <home>
  local worktree=$1 id=$2 home=$3 marker tmp
  [ -n "$id" ] || return 1
  marker=$(fm_treehouse_slot_owner_marker "$worktree") || return 1
  # Only a plain claim file may be replaced: renaming onto a directory would
  # move the new claim inside it and leave the slot reading as unclaimable.
  if { [ -e "$marker" ] || [ -L "$marker" ]; } \
     && { [ ! -f "$marker" ] || [ -L "$marker" ]; }; then
    return 1
  fi
  tmp="$marker.tmp.${BASHPID:-$$}"
  rm -f "$tmp" || return 1
  {
    printf 'task=%s\n' "$id"
    printf 'home=%s\n' "$home"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$marker" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Read the claim on a pool slot and compare it with a task id.
# Sets FM_TREEHOUSE_SLOT_OWNER to one of:
#   mine   - the claim names this task
#   other  - the claim names a different task, so the slot was reassigned
#   absent - no claim: the slot was taken before claims existed, or returned since
#   unsafe - a claim file exists but cannot be read as a claim
# FM_TREEHOUSE_SLOT_OWNER_ID and FM_TREEHOUSE_SLOT_OWNER_HOME carry the recorded
# claimant as evidence. The home is reported, never matched: a home that moved
# must not turn a task's own slot into a refusal.
fm_treehouse_slot_owner_state() {  # <worktree> <task-id>
  local worktree=$1 id=$2 marker line owner_id='' owner_home=''
  FM_TREEHOUSE_SLOT_OWNER=unsafe
  FM_TREEHOUSE_SLOT_OWNER_ID=
  FM_TREEHOUSE_SLOT_OWNER_HOME=
  marker=$(fm_treehouse_slot_owner_marker "$worktree") || return 0
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    FM_TREEHOUSE_SLOT_OWNER=absent
    return 0
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      task=*) owner_id=${line#task=} ;;
      home=*) owner_home=${line#home=} ;;
    esac
  done < "$marker" || return 0
  [ -n "$owner_id" ] || return 0
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_SLOT_OWNER_ID=$owner_id
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_SLOT_OWNER_HOME=$owner_home
  if [ "$owner_id" = "$id" ]; then
    FM_TREEHOUSE_SLOT_OWNER=mine
  else
    FM_TREEHOUSE_SLOT_OWNER=other
  fi
}

# Drop a task's own claim once its slot is back in the pool. Never removes
# another task's claim, so a misdirected release cannot strip the evidence that
# protects the slot's real owner.
fm_treehouse_slot_owner_release() {  # <worktree> <task-id>
  local worktree=$1 id=$2 marker
  fm_treehouse_slot_owner_state "$worktree" "$id"
  [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] || return 0
  marker=$(fm_treehouse_slot_owner_marker "$worktree") || return 0
  rm -f "$marker" 2>/dev/null || true
}
