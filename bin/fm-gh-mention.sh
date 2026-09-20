#!/usr/bin/env bash
# fm-gh-mention.sh - the GitHub mention plane: route a tagged comment in a
# watched repository into firstmate's durable wake queue.
#
# Usage:
#   fm-gh-mention.sh poll             read every watched repo's new activity and accept qualifying mentions
#   fm-gh-mention.sh pending          print the accepted-but-unhandled records as JSON
#   fm-gh-mention.sh ack <record-id>  move one handled record into gh-mention-inbox/handled/
#   fm-gh-mention.sh status           local-only summary: config, watched repos, cursors, pending count
#   fm-gh-mention.sh cadence          print the watcher interval this plane asks for, or nothing
#   fm-gh-mention.sh arm              write and register state/gh-mention.check.sh
#   fm-gh-mention.sh disarm           remove the check shim and its trust binding
#   fm-gh-mention.sh --help           print this help
#
# INERT BY DEFAULT. Without config/gh-mentions.json this plane is a complete
# no-op: nothing is armed, poll exits 0 in silence, and no existing path pays
# for it. docs/configuration.md "GitHub mentions" owns the configuration schema.
#
# WHAT IS WATCHED IS REPOSITORIES, NOT ACCOUNTS. The watched set is this home's
# registered projects (each project's projects/<name> clone contributes its
# github.com origin as owner/name) plus every owner/name in the config's `repos`
# array, which covers a repo that should be watched without being cloned here.
# Which account owns a watched repo is irrelevant: a qualifying mention is
# handled identically in all of them.
#
# TRUST IS THE SAFETY CORE. A body qualifies only when BOTH hold on that same
# body: its author's GitHub login is on `trusted_logins` (matched exactly,
# case-insensitively, by login and never by display name), and that body carries
# one of the configured `markers` (matched case-insensitively as a literal
# substring). The marker is what separates a request meant for firstmate from
# ordinary conversation by a trusted account. Text quoted or embedded from
# another account never qualifies on its own, because only the body's own author
# is checked. Everything else is ignored silently: no record, no wake, no forge
# write. Authorizing a collaborator is exactly adding their login to
# `trusted_logins`, and every listed login carries the same authority.
#
# THE POLL PERFORMS NO FORGE WRITES AT ALL. It reads three repo-scoped listings
# per repo per poll, each bounded by a `since` cursor so the cost is a small
# constant per repo rather than growing with repo history:
#   repos/<o>/<r>/issues/comments  issue and PR conversation comments
#   repos/<o>/<r>/pulls/comments   PR review comments
#   repos/<o>/<r>/issues           newly opened or edited issue and PR bodies
# Repos are read oldest-cursor first and at most FM_GH_MENTION_MAX_REPOS of them
# per sweep, so a watched set too large for one sweep rotates across sweeps
# instead of starving its tail. A repo whose reads do not all complete keeps its
# cursor, so nothing is skipped. The cap is what keeps the hourly cost fixed:
# 3 x cap x (3600 / interval) calls, and a larger watched set buys a longer
# worst-case pickup - ceil(watched / cap) x interval - rather than an exhausted
# allowance shared with every other gh-backed plane on this host.
#
# DURABLE STATE (all under state/, all gitignored):
#   gh-mention-inbox/<record-id>.json          one accepted mention, pending
#   gh-mention-inbox/handled/<record-id>.json  the same record after ack
#   gh-mention-cursor.json                     per-repo since cursors and the
#                                              bounded processed-id list
#   gh-mention.reported                        the failure diagnostics the last
#                                              poll printed, so a condition that
#                                              outlives one poll is reported once
# A record id is the mention's own GitHub identity - issue-<id> for an issue or
# PR body, comment-<id> for a conversation comment, review-comment-<id> for a PR
# review comment - so a repeated poll re-derives the same id and never files the
# same mention twice. Record fields (schema fm-gh-mention.v1): record_id,
# repository, subject_type (issue|pull), subject_number, subject_url,
# comment_kind (body|comment|review-comment), comment_id, comment_url, author,
# marker, body, accepted_at.
#
# Each accepted record appends exactly one durable `check: gh-mention
# <record-id>` wake through bin/fm-wake-lib.sh, keyed so a poll that runs again
# before the drain does not queue it twice. The record is written BEFORE the
# wake and the processed-id list is extended AFTER it, so a crash can duplicate
# a wake but can never consume a pending record.
#
# AN UNWRITABLE state/ STOPS THIS PLANE, IT DOES NOT DEGRADE IT. Every durable
# step fails closed: a bound that cannot be spent refuses its mention, a mention
# that cannot be filed holds its repo at its cursor, and a lapse that cannot be
# recorded is not announced. The hold is what keeps a mention from being stepped
# over, but a permanently unwritable state/ means that repo re-reads the same
# window forever, and once more than one page accumulates in it, newer tagged
# comments fall beyond page one and are never read. The condition is reported
# once, so this is loud exactly once: a `could not` line from this plane is
# blocking, and the repo resumes from its cursor once state/ is writable again.
#
# RESPONSE LATENCY. An enabled plane asks the home's watcher for a sweep every
# `check_interval` seconds (default 30) instead of the default 300, so a tagged
# comment is picked up in tens of seconds. That request goes through the one
# cadence config/x-mode.env that bin/fm-bootstrap.sh already owns for Relay: a
# home running both planes gets one interval, the fastest either asked for,
# never two. A tight cadence is affordable because the per-poll cost is fixed at
# three reads per capped repo; a large watched set costs pickup time rather
# than allowance, so a longer `check_interval` buys the host headroom.
#
# Environment:
#   FM_GH_MENTION_BUDGET    seconds one poll may spend on forge reads
#                           (default 20, valid 1..25, cut down to fit
#                           FM_CHECK_TIMEOUT); each call is additionally bounded
#   FM_GH_MENTION_BACKFILL  seconds of history read for a repo that has no
#                           cursor yet (default 3600)
#   FM_GH_MENTION_MAX_REPOS watched repos one sweep may read (default 5); the
#                           rest are read on the following sweeps, oldest first
#   FM_GH_MENTION_KEEP      processed ids retained in the cursor (default 500)
#   FM_GH_MENTION_NOW       ISO UTC clock override for tests
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="$CONFIG_DIR/gh-mentions.json"
CHECK_ID=gh-mention
INBOX="$STATE/gh-mention-inbox"
CURSOR="$STATE/gh-mention-cursor.json"
REPORT_RECORD="$STATE/gh-mention.reported"
LOCK="$STATE/.gh-mention.lock"
CURSOR_SCHEMA=fm-gh-mention-cursor.v1
RECORD_SCHEMA=fm-gh-mention.v1
BODY_MAX=4000
PER_PAGE=100

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-check-shim-lib.sh
. "$SCRIPT_DIR/fm-check-shim-lib.sh"

usage() { sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"; }
say() { printf 'gh-mention: %s\n' "$1"; }
die() { printf 'fm-gh-mention: %s\n' "$1" >&2; exit 2; }

# ------------------------------------------------------- reported-once failures
#
# The watcher wakes firstmate on ANY non-empty check output, so a failure that
# outlives one poll - an unreadable repo, a missing tool, a broken config -
# must be reported once rather than on every cycle, or it tears the watcher
# down at this plane's own 30s cadence forever. bin/fm-x-poll.sh and
# bin/fm-mail-check.sh keep the same contract against the same watcher.
# Diagnostics therefore go to diag() and are flushed once at the end of a poll;
# news (an accepted mention, a grant that just lapsed) is a one-off event that
# always prints through say().
DIAGNOSTICS=

diag() {  # <message>
  DIAGNOSTICS="${DIAGNOSTICS}gh-mention: $1"$'\n'
}

report_record_write() {  # <reported-text>; empty forgets what was reported
  local staged
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  if [ -z "$1" ]; then
    rm -f -- "$REPORT_RECORD"
    return 0
  fi
  staged=$(umask 077; mktemp "$STATE/.gh-mention-reported.XXXXXX") || return 1
  if ! printf '%s\n' "$1" > "$staged" || ! chmod 0600 "$staged" \
    || ! mv -f -- "$staged" "$REPORT_RECORD"; then
    rm -f -- "$staged"
    return 1
  fi
}

# Print this poll's diagnostics unless the last poll already reported exactly
# them, then record what was reported. A condition that clears is forgotten, so
# it is reported again if it returns. Reporting before recording makes a record
# that cannot be written cost a repeated report rather than a lost one.
diag_flush() {
  local pending=${DIAGNOSTICS%$'\n'} previous=
  DIAGNOSTICS=
  if [ -f "$REPORT_RECORD" ] && [ ! -L "$REPORT_RECORD" ]; then
    previous=$(cat "$REPORT_RECORD" 2>/dev/null) || previous=
  fi
  [ "$pending" != "$previous" ] || return 0
  [ -z "$pending" ] || printf '%s\n' "$pending"
  report_record_write "$pending" || true
}

TMP=
LOCK_HELD=0
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK" || true
  [ -z "$TMP" ] || rm -rf -- "$TMP"
}

now_iso() {
  case "${FM_GH_MENTION_NOW:-}" in
    '') date -u +%Y-%m-%dT%H:%M:%SZ ;;
    *) printf '%s\n' "$FM_GH_MENTION_NOW" ;;
  esac
}

# ---------------------------------------------------------------- config

# Sets CFG_* on success. Return 0 valid, 1 absent (the inert default), 2
# invalid. An invalid config is reported by every caller and stops the plane; it
# is never repaired by a guessed default, because a typo in `trusted_logins`
# would otherwise silently widen or narrow who firstmate obeys.
CONFIG_PROBLEM=
config_load() {
  local parsed
  CONFIG_PROBLEM=
  CFG_ENABLED=false
  CFG_TRUSTED=
  CFG_MARKERS=
  CFG_REPOS=
  CFG_TRUSTED_JSON='[]'
  CFG_MARKERS_JSON='[]'
  CFG_INTERVAL=
  [ -e "$CONFIG" ] || return 1
  if [ -L "$CONFIG" ] || [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
    CONFIG_PROBLEM='config/gh-mentions.json is not a readable regular file'
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    CONFIG_PROBLEM='jq is required to read config/gh-mentions.json'
    return 2
  fi
  if [ ! -f "$SCRIPT_DIR/fm-gh-mention-config.jq" ]; then
    CONFIG_PROBLEM="the configuration validator is missing at $SCRIPT_DIR/fm-gh-mention-config.jq"
    return 2
  fi
  if ! parsed=$(jq -r -f "$SCRIPT_DIR/fm-gh-mention-config.jq" "$CONFIG" 2>/dev/null); then
    CONFIG_PROBLEM='config/gh-mentions.json is not valid JSON'
    return 2
  fi
  case "$parsed" in
    'invalid: '*) CONFIG_PROBLEM="config/gh-mentions.json ${parsed#invalid: }"; return 2 ;;
  esac
  CFG_ENABLED=$(printf '%s\n' "$parsed" | sed -n '1p')
  CFG_INTERVAL=$(printf '%s\n' "$parsed" | sed -n '2p')
  CFG_TRUSTED=$(printf '%s\n' "$parsed" | sed -n '/^--trusted$/,/^--markers$/p' | sed '1d;$d')
  CFG_MARKERS=$(printf '%s\n' "$parsed" | sed -n '/^--markers$/,/^--repos$/p' | sed '1d;$d')
  CFG_REPOS=$(printf '%s\n' "$parsed" | sed -n '/^--repos$/,$p' | sed '1d')
  # The forms the selection filter consumes, built once here rather than once
  # per watched repository. CFG_TRUSTED is one compact grant object per line.
  CFG_TRUSTED_JSON=$(printf '%s\n' "$CFG_TRUSTED" | jq -sc '.') || return 2
  CFG_MARKERS_JSON=$(printf '%s\n' "$CFG_MARKERS" \
    | jq -Rsc 'split("\n") | map(select(length > 0))') || return 2
  return 0
}

# Refuse to act on a config this home cannot read the way it was written.
config_require() {
  local rc=0
  config_load || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) diag "$CONFIG_PROBLEM"; return 2 ;;
  esac
}

# ---------------------------------------------------------------- watched set

# A registered project contributes the github.com repository its clone points
# at. Rows are typed so a caller chooses what to do with each kind: "repo" is a
# watched repository, "skip" is a registered project this home cannot resolve to
# one. Silently watching fewer repos than the captain registered is the failure
# this plane must not have, so a skip is never dropped on the floor - the poll
# stays quiet about it and status and arm report it.
registry_repos() {
  local name url
  [ -f "$DATA/projects.md" ] && [ ! -L "$DATA/projects.md" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ ! -e "$PROJECTS/$name/.git" ]; then
      printf 'skip\t%s\t%s\n' "$name" 'has no clone here'
      continue
    fi
    url=$(git -C "$PROJECTS/$name" remote get-url origin 2>/dev/null) || url=
    case "$url" in
      https://github.com/*|git@github.com:*|ssh://git@github.com/*) ;;
      '') printf 'skip\t%s\t%s\n' "$name" 'has no origin remote'; continue ;;
      *) printf 'skip\t%s\t%s\n' "$name" 'is not on github.com'; continue ;;
    esac
    url=${url#https://github.com/}
    url=${url#git@github.com:}
    url=${url#ssh://git@github.com/}
    url=${url%.git}
    url=${url%/}
    case "$url" in
      */*/*) printf 'skip\t%s\t%s\n' "$name" 'has an origin this plane cannot read as owner/name' ;;
      */*) printf 'repo\t%s\n' "$url" ;;
      *) printf 'skip\t%s\t%s\n' "$name" 'has an origin this plane cannot read as owner/name' ;;
    esac
  done < <(awk '$1 == "-" && $2 ~ /^[A-Za-z0-9._-]+$/ { print $2 }' "$DATA/projects.md")
}

# The watched set: every resolvable registered project plus every repo the
# config lists outright, deduped into a stable order.
watched_repos() {
  { registry_repos | awk -F'\t' '$1 == "repo" { print $2 }'; printf '%s\n' "$CFG_REPOS"; } \
    | sed '/^$/d' | sort -u
}

# One human-readable line per registered project that contributes no repository.
unwatched_projects() {
  registry_repos | awk -F'\t' \
    '$1 == "skip" { printf "registered project %s %s; it is not watched\n", $2, $3 }'
}

# ---------------------------------------------------------------- cursor

cursor_read() {
  if [ -f "$CURSOR" ] && [ ! -L "$CURSOR" ] \
    && jq -e --arg s "$CURSOR_SCHEMA" '.schema == $s and (.repos|type=="object")
        and (.processed|type=="array")
        and ((.grants // {}) | type == "object") and ((.lapsed // []) | type == "array")' \
      "$CURSOR" >/dev/null 2>&1; then
    cat "$CURSOR"
    return 0
  fi
  jq -n --arg s "$CURSOR_SCHEMA" '{schema:$s,repos:{},processed:[],grants:{},lapsed:[]}'
}

cursor_write() {  # <cursor-json-file>
  local src=$1 device staged
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CURSOR" "$device" || return 1
  staged=$(umask 077; mktemp "$STATE/.gh-mention-cursor.XXXXXX") || return 1
  if ! cat "$src" > "$staged" || ! chmod 0600 "$staged" \
    || ! fm_pr_private_file_valid "$staged" 600 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CURSOR" "$device" \
    || ! mv -f -- "$staged" "$CURSOR"; then
    rm -f -- "$staged"
    return 1
  fi
}

# ---------------------------------------------------------------- forge reads

# One bounded read. The budget, not GitHub, is what refuses a late call, and a
# read killed at the budget's own deadline counts as exhaustion rather than as a
# repo that failed.
BUDGET_EXHAUSTED=0
RATE_LIMITED=0
forge() {  # <api-path> <output-file>
  local path=$1 out=$2 remaining bounded=0 rc=0
  remaining=$((DEADLINE - $(date +%s)))
  [ "$remaining" -gt 0 ] || { BUDGET_EXHAUSTED=1; return 1; }
  if [ "$remaining" -le 5 ]; then bounded=1; else remaining=5; fi
  fm_run_timed "$remaining" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh api -H 'Accept: application/vnd.github+json' "$path" > "$out" 2>/dev/null || rc=$?
  [ "$rc" -ne 124 ] || [ "$bounded" -eq 0 ] || BUDGET_EXHAUSTED=1
  if [ "$rc" -ne 0 ]; then
    # A refused allowance is a whole-host condition, not one unreadable repo,
    # so it is recognized from the error body GitHub documents for 403 and 429.
    jq -e '(.message? // "") | ascii_downcase
      | test("rate limit|abuse detection")' "$out" >/dev/null 2>&1 && RATE_LIMITED=1
    return 1
  fi
  jq -e 'type == "array"' "$out" >/dev/null 2>&1
}

# The three repo-scoped listings, each bounded by the same `since` cursor and
# normalized into one candidate stream: {record_id, comment_kind, comment_id,
# comment_url, author, body}. Only these three calls per repo per poll.
#
# Each listing is asked for its oldest page first, so a repo with more new
# activity than one page holds is read in order rather than sampled. A full page
# means there is more behind it, so read_repo also reports the newest moment
# this repo's cursor may advance to without stepping over what it did not read;
# empty means every listing was read to its end.
read_repo() {  # <owner/name> <since-iso> <candidates-out> <cursor-bound-out>
  local repo=$1 since=$2 out=$3 bound=$4 q
  q="per_page=$PER_PAGE&sort=updated&direction=asc&since=$since"
  forge "repos/$repo/issues/comments?$q" "$TMP/comments.json" || return 1
  forge "repos/$repo/pulls/comments?$q" "$TMP/review.json" || return 1
  forge "repos/$repo/issues?state=all&$q" "$TMP/issues.json" || return 1
  jq -r -n --slurpfile c "$TMP/comments.json" --slurpfile r "$TMP/review.json" \
    --slurpfile i "$TMP/issues.json" --argjson page "$PER_PAGE" '
    [$c[0], $r[0], $i[0]]
    | map(select(length >= $page) | (.[-1].updated_at // empty))
    | if length == 0 then "" else min end' > "$bound" || return 1
  jq -c -n --slurpfile c "$TMP/comments.json" --slurpfile r "$TMP/review.json" \
    --slurpfile i "$TMP/issues.json" '
    def norm($kind; $prefix):
      map(select((.user.login | type) == "string" and (.body | type) == "string"
          and (.html_url | type) == "string" and (.id | type) == "number")
        | {record_id: ($prefix + (.id | tostring)), comment_kind: $kind,
           comment_id: .id, comment_url: .html_url,
           author: .user.login, body: .body});
    (($c[0] | norm("comment"; "comment-"))
      + ($r[0] | norm("review-comment"; "review-comment-"))
      + ($i[0] | norm("body"; "issue-")))[]' > "$out"
}

# ---------------------------------------------------------------- grants

# An authorization may be permanent or bounded. A bounded grant ends at its
# `until` time, after `remaining` accepted mentions, or at whichever of the two
# comes first. The configured count is the captain's; what this home has already
# spent lives in the cursor, so the plane never rewrites the captain's file and
# an entry is never deleted when it lapses.
#
# Prints the logins that are live right now, lowercased, one per line.
grants_live() {  # <cursor-json> <now-iso>
  jq -r --slurpfile c "$1" --arg now "$2" --argjson trusted "$CFG_TRUSTED_JSON" '
    ($now | fromdateiso8601) as $t
    | ($c[0].grants // {}) as $spent
    | $trusted[]
    | (.login | ascii_downcase) as $id
    | select((.until == null) or ((.until | fromdateiso8601) > $t))
    | select((.remaining == null)
        or (.remaining - (($spent[$id].spent_on // []) | length) > 0))
    | $id' "$1" 2>/dev/null
}

# The bounded grants that have ended and have not been reported yet, so a
# captain who stops being able to tag learns why once instead of guessing.
grants_lapsed_unreported() {  # <cursor-json> <now-iso>
  jq -r --slurpfile c "$1" --arg now "$2" --argjson trusted "$CFG_TRUSTED_JSON" '
    ($now | fromdateiso8601) as $t
    | ($c[0].grants // {}) as $spent
    | ($c[0].lapsed // []) as $reported
    | $trusted[]
    | select(.until != null or .remaining != null)
    | (.login | ascii_downcase) as $id
    | select(($reported | index($id)) == null)
    | select(((.until != null) and ((.until | fromdateiso8601) <= $t))
        or ((.remaining != null) and (.remaining - (($spent[$id].spent_on // []) | length) <= 0)))
    | $id + "\t" + (if (.until != null) and ((.until | fromdateiso8601) <= $t)
        then "its authorization expired at " + .until
        else "it used all " + (.remaining | tostring) + " of its authorized requests" end)' \
    "$1" 2>/dev/null
}

# One readable line per authorization, with its bound and whether it is still
# live, so the operator can see at a glance why an account can or cannot tag.
grants_describe() {  # <cursor-json> <now-iso>
  jq -r --slurpfile c "$1" --arg now "$2" --argjson trusted "$CFG_TRUSTED_JSON" '
    ($now | fromdateiso8601) as $t
    | ($c[0].grants // {}) as $spent
    | $trusted[]
    | (.login | ascii_downcase) as $id
    | (($spent[$id].spent_on // []) | length) as $used
    | ((.until != null) and ((.until | fromdateiso8601) <= $t)) as $expired
    | ((.remaining != null) and (.remaining - $used <= 0)) as $exhausted
    | .login
      + (if .until == null and .remaining == null then " - permanent" else
          " - " + ([(if .until != null then "until " + .until else empty end),
                    (if .remaining != null then
                       ((.remaining - $used | if . < 0 then 0 else . end) | tostring)
                       + " of " + (.remaining | tostring) + " requests left"
                     else empty end)] | join(", "))
        end)
      + (if $expired or $exhausted then " (LAPSED)" else "" end)' "$1" 2>/dev/null
}

# Report each bounded authorization that has ended and has not been reported
# yet, so a captain whose tagging stopped working learns why once instead of
# guessing. The entry is never deleted and never auto-renewed.
#
# The report is recorded durably BEFORE it is made, the same order grant_charge
# spends a bound in. This is news rather than a diagnostic, so nothing
# suppresses a repeat of it; an announcement this home cannot remember would
# repeat on every poll, and a repeated line is a repeated wake. A lapse whose
# record cannot be written therefore stays silent, and `status` still shows it.
grants_report_lapsed() {  # <cursor-json> <now-iso>
  local id why
  while IFS=$'\t' read -r id why; do
    [ -n "$id" ] || continue
    jq --arg id "$id" '.lapsed = (((.lapsed // []) + [$id]) | unique)' "$1" > "$TMP/lapsed.json" \
      || continue
    cursor_write "$TMP/lapsed.json" || continue
    mv -f -- "$TMP/lapsed.json" "$1" || continue
    say "the bounded authorization for $id has lapsed because $why; it no longer qualifies until the captain renews it"
  done < <(grants_lapsed_unreported "$1" "$2")
}

# Charge one accepted mention to a bounded grant, and persist that charge
# before the mention is accepted. Returns 0 when the author may be acted on, 2
# when the grant is not live, and 1 when the charge could not be made durable.
#
# The charge records WHICH mention it paid for, so it is idempotent: a poll that
# crashed between charging and filing re-derives the same record id and charges
# nothing further, and a grant with one request left can never fund two
# mentions. What remains is the configured count minus the mentions already
# funded, so the captain's own file is never rewritten.
#
# This fails closed on purpose: a count this home cannot read or durably record
# must not authorize work, so an unwritable cursor refuses the mention rather
# than accepting it on a bound nobody can verify. The poll holds this plane's
# lock throughout, so no concurrent poll can charge the same grant at once.
grant_charge() {  # <author-login> <record-id> <cursor-json> <now-iso>
  local login=$1 record=$2 out=$3 now=$4 id state
  id=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')
  state=$(jq -rn --arg id "$id" --arg rec "$record" --arg now "$now" --slurpfile c "$out" \
    --argjson trusted "$CFG_TRUSTED_JSON" '
    ($now | fromdateiso8601) as $t
    | ($c[0].grants // {}) as $spent
    | (($spent[$id].spent_on // [])) as $funded
    | ([$trusted[] | select((.login | ascii_downcase) == $id)] | first)
    | if . == null then "absent"
      elif (.until != null) and ((.until | fromdateiso8601) <= $t) then "lapsed"
      elif .remaining == null then "permanent"
      elif ($funded | index($rec)) != null then "already-charged"
      elif (.remaining - ($funded | length)) <= 0 then "lapsed"
      else "bounded" end') || return 1
  case "$state" in
    permanent|already-charged) return 0 ;;
    bounded) ;;
    *) return 2 ;;
  esac
  jq --arg id "$id" --arg rec "$record" \
    '.grants[$id].spent_on = (((.grants[$id].spent_on) // []) + [$rec] | unique)' "$out" \
    > "$TMP/charge.json" || return 1
  mv -f -- "$TMP/charge.json" "$out" || return 1
  cursor_write "$out"
}

# ---------------------------------------------------------------- selection

# The safety core, stated once and declaratively: a candidate survives only when
# its own author is trusted AND its own body carries a configured marker.
qualify() {  # <candidates-in> <repo> <qualified-out>
  jq -c --arg repo "$2" --argjson trusted "$LIVE_LOGINS_JSON" \
    --argjson markers "$CFG_MARKERS_JSON" --argjson cap "$BODY_MAX" '
    . as $c
    | ($c.author | ascii_downcase) as $login
    | select(any($trusted[]; . == $login))
    | [$markers[] as $m | select(($c.body | ascii_downcase) | contains($m | ascii_downcase)) | $m] as $hit
    | select(($hit | length) > 0)
    | ($c.comment_url | split("#")[0]) as $subject
    | ($subject | split("/")) as $seg
    | $c + {marker: $hit[0], repository: $repo, subject_url: $subject,
            subject_type: (if $seg[-2] == "pull" then "pull" else "issue" end),
            subject_number: (($seg[-1] | tonumber?) // 0),
            body: ($c.body[:$cap])}' "$1" > "$3"
}

# ---------------------------------------------------------------- records

record_write() {  # <record-id> <record-json-file>
  local id=$1 src=$2 device staged
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$INBOX" ] && [ ! -L "$INBOX" ] || return 1
  device=$(fm_pr_file_device "$INBOX") || return 1
  fm_pr_regular_destination_on_device_or_absent "$INBOX/$id.json" "$device" || return 1
  staged=$(umask 077; mktemp "$INBOX/.staging.XXXXXX") || return 1
  if ! cat "$src" > "$staged" || ! chmod 0600 "$staged" \
    || ! fm_pr_private_file_valid "$staged" 600 "$device" \
    || ! mv -f -- "$staged" "$INBOX/$id.json"; then
    rm -f -- "$staged"
    return 1
  fi
}

# Write the record, then wake, then remember the id. That order is what keeps a
# crash from consuming a pending mention: a repeated poll re-derives the same id
# and finishes the steps the interrupted one did not.
accept() {  # <record-json-file> <record-id> <accepted-at>
  local src=$1 id=$2 at=$3 status=0
  jq --arg s "$RECORD_SCHEMA" --arg at "$at" \
    '{schema:$s} + . + {accepted_at:$at}' "$src" > "$TMP/record.json" || return 1
  record_write "$id" "$TMP/record.json" || return 1
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if ! fm_wake_queued_keys_locked check | grep -Fx "gh-mention:$id" >/dev/null; then
    fm_wake_append_locked check "gh-mention:$id" "check: gh-mention $id" || status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

# ---------------------------------------------------------------- poll

acquire() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die 'state directory is unavailable'
  FM_WAKE_QUEUE="$STATE/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$LOCK" || die 'mention lock unavailable'
  LOCK_HELD=1
}

# Sets BUDGET. fm_run_timed counts a whole second before it alarms, so the
# budget has to fit inside the watcher's own per-check bound with the alarm and
# kill margins left over; a budget larger than that is cut down rather than
# refused, while a budget that is not a whole number 1..25 is refused outright.
resolve_budget() {
  local timeout max
  timeout=${FM_CHECK_TIMEOUT:-30}
  case "$timeout" in ''|*[!0-9]*|0) timeout=30 ;; esac
  BUDGET=${FM_GH_MENTION_BUDGET:-20}
  case "$BUDGET" in
    ''|*[!0-9]*|0) die 'FM_GH_MENTION_BUDGET must be a whole number from 1 to 25' ;;
  esac
  [ "$BUDGET" -ge 1 ] && [ "$BUDGET" -le 25 ] \
    || die 'FM_GH_MENTION_BUDGET must be a whole number from 1 to 25'
  max=$((timeout - 3))
  [ "$max" -ge 1 ] || max=1
  [ "$BUDGET" -le "$max" ] || BUDGET=$max
}

# One repo's turn: read, qualify, file what is new. The cursor advances only
# after every read for that repo succeeded AND every qualifying mention in the
# window was filed, so a bounded read, a failed read, or a mention that could
# not be filed costs a repeat rather than a missed mention.
poll_repo() {  # <owner/name> <cursor-json> <poll-start-iso> <new-cursor-out>
  local repo=$1 state_json=$2 start=$3 out=$4 since line id advance charge unfiled=0
  since=$(jq -r --arg r "$repo" --arg b "$BACKFILL_SINCE" '.repos[$r] // $b' "$state_json")
  cp "$state_json" "$out" || return 1
  if ! read_repo "$repo" "$since" "$TMP/candidates.jsonl" "$TMP/bound"; then
    if [ "$RATE_LIMITED" -eq 1 ]; then
      diag "GitHub refused this host's API allowance, so no watched repository was read this cycle; every gh-backed plane on this host is affected until the allowance resets"
    elif [ "$BUDGET_EXHAUSTED" -eq 0 ]; then
      diag "could not read $repo this cycle; it is retried next cycle"
    fi
    return 1
  fi
  if ! qualify "$TMP/candidates.jsonl" "$repo" "$TMP/qualified.jsonl"; then
    diag "could not read $repo's new activity; it is retried next cycle"
    return 1
  fi
  jq -c --slurpfile c "$state_json" '
    ($c[0].processed // []) as $seen
    | .record_id as $id
    | select(any($seen[]; . == $id) | not)' "$TMP/qualified.jsonl" > "$TMP/new.jsonl" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" > "$TMP/one.json"
    id=$(jq -r '.record_id' "$TMP/one.json") || continue
    fm_pr_task_id_valid "$id" || continue
    [ ! -e "$INBOX/handled/$id.json" ] || continue
    grant_charge "$(jq -r '.author' "$TMP/one.json")" "$id" "$out" "$start"
    charge=$?
    case "$charge" in
      0) ;;
      2) continue ;;
      *) diag "could not durably record a bounded authorization being spent; this mention is not accepted"
         unfiled=1
         continue ;;
    esac
    if accept "$TMP/one.json" "$id" "$start"; then
      say "$(jq -r '"\(.author) tagged \(.marker) on \(.subject_url)"' "$TMP/one.json") (record $id)"
      jq --arg id "$id" --argjson keep "$KEEP" \
        '.processed = ((.processed - [$id]) + [$id] | .[-$keep:])' "$out" > "$TMP/next.json" \
        && mv -f -- "$TMP/next.json" "$out"
    else
      diag "could not file a mention from $repo; it stays unfiled until the next cycle"
      unfiled=1
    fi
  done < "$TMP/new.jsonl"
  # A mention this window qualified but could not file is only genuinely
  # retried if the window is read again, so the cursor stays where it was.
  [ "$unfiled" -eq 0 ] || return 1
  # A full page means this poll did not reach the present, so the cursor stops
  # at the last moment actually read; the next poll continues from there instead
  # of stepping over what the page cut off.
  advance=$(cat "$TMP/bound")
  [ -n "$advance" ] || advance=$OVERLAP_SINCE
  jq --arg r "$repo" --arg t "$advance" '.repos[$r] = $t' "$out" > "$TMP/next.json" \
    && mv -f -- "$TMP/next.json" "$out"
}

# Every failure this cycle is collected rather than printed, so the one flush
# below decides what the watcher actually sees.
action_poll() {
  poll_cycle
  diag_flush
  return 0
}

poll_cycle() {
  local start repos repo state_json next swept
  config_require || return 0
  [ "$CFG_ENABLED" = true ] || return 0
  command -v gh >/dev/null 2>&1 || { diag 'gh is required to read watched repositories'; return 0; }
  command -v jq >/dev/null 2>&1 || { diag 'jq is required to read watched repositories'; return 0; }
  resolve_budget
  acquire
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-mention.XXXXXX") || die 'no scratch directory'
  start=$(now_iso)
  # An unusable clock would send every listing an empty `since` and read each
  # repo's whole history, so it stops the poll instead.
  BACKFILL_SINCE=$(iso_shift "$start" "${FM_GH_MENTION_BACKFILL:-3600}") || BACKFILL_SINCE=
  OVERLAP_SINCE=$(iso_shift "$start" 60) || OVERLAP_SINCE=
  if [ -z "$BACKFILL_SINCE" ] || [ -z "$OVERLAP_SINCE" ]; then
    diag "cannot read the clock as a UTC timestamp ($start)"
    return 0
  fi
  KEEP=${FM_GH_MENTION_KEEP:-500}
  case "$KEEP" in ''|*[!0-9]*|0) KEEP=500 ;; esac
  MAX_REPOS=${FM_GH_MENTION_MAX_REPOS:-5}
  case "$MAX_REPOS" in ''|*[!0-9]*|0) MAX_REPOS=5 ;; esac
  repos=$(watched_repos)
  [ -n "$repos" ] || return 0
  mkdir -p "$INBOX" || die 'mention inbox unavailable'
  DEADLINE=$(( $(date +%s) + BUDGET ))
  state_json="$TMP/cursor.json"
  cursor_read > "$state_json"
  grants_report_lapsed "$state_json" "$start"
  LIVE_LOGINS_JSON=$(grants_live "$state_json" "$start" \
    | jq -Rsc 'split("\n") | map(select(length > 0))') || LIVE_LOGINS_JSON=
  if [ -z "$LIVE_LOGINS_JSON" ]; then
    diag 'could not read which authorizations are still live; no mention is accepted this cycle'
    return 0
  fi
  # A renewed grant becomes reportable again the next time it lapses.
  jq --argjson live "$LIVE_LOGINS_JSON" '.lapsed = (((.lapsed // []) - $live))' "$state_json" \
    > "$TMP/relive.json" && mv -f -- "$TMP/relive.json" "$state_json"
  next="$TMP/cursor-next.json"
  swept=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    [ "$swept" -lt "$MAX_REPOS" ] || break
    [ "$(date +%s)" -lt "$DEADLINE" ] || break
    poll_repo "$repo" "$state_json" "$start" "$next" || true
    swept=$((swept + 1))
    mv -f -- "$next" "$state_json"
    [ "$BUDGET_EXHAUSTED" -eq 0 ] && [ "$RATE_LIMITED" -eq 0 ] || break
  done < <(order_by_cursor "$state_json" "$repos")
  cursor_write "$state_json" || diag 'could not record how far the watched repositories were read'
  return 0
}

# Oldest cursor first, so one budget's worth of reads rotates through a watched
# set too large to finish in a single poll instead of always starving its tail.
order_by_cursor() {  # <cursor-json> <repo-list>
  local state_json=$1 repos=$2
  printf '%s\n' "$repos" | while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    printf '%s\t%s\n' "$(jq -r --arg r "$repo" '.repos[$r] // ""' "$state_json")" "$repo"
  done | sort | cut -f2-
}

iso_shift() {  # <iso-utc> <seconds-back>
  local iso=$1 back=$2 epoch
  epoch=$(jq -nr --arg t "$iso" '$t | fromdateiso8601' 2>/dev/null) || return 1
  case "$back" in ''|*[!0-9]*) back=0 ;; esac
  jq -nr --argjson e "$((epoch - back))" '$e | todateiso8601'
}

# ---------------------------------------------------------------- other actions

action_pending() {
  local f
  [ -d "$INBOX" ] || { printf '[]\n'; return 0; }
  { for f in "$INBOX"/*.json; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      jq -c . "$f" 2>/dev/null \
        || printf 'fm-gh-mention: %s is unreadable and is not listed\n' "$f" >&2
    done; } | jq -s 'sort_by(.accepted_at)'
}

action_ack() {  # <record-id>
  local id=${1:-}
  fm_pr_task_id_valid "$id" || die 'ack needs one valid record id'
  mkdir -p "$INBOX/handled" || die 'mention inbox unavailable'
  if [ -f "$INBOX/$id.json" ] && [ ! -L "$INBOX/$id.json" ]; then
    mv -f -- "$INBOX/$id.json" "$INBOX/handled/$id.json" || die "could not acknowledge $id"
    printf 'acked %s\n' "$id"
    return 0
  fi
  printf 'already-acked %s\n' "$id"
}

action_status() {
  local rc=0 repos pending=0
  config_load || rc=$?
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-mention.XXXXXX") || die 'no scratch directory'
  TMP_STATUS="$TMP/cursor.json"
  case "$rc" in
    1) printf 'gh mentions: off (no config/gh-mentions.json)\n'; return 0 ;;
    2) printf 'gh mentions: stopped - %s\n' "$CONFIG_PROBLEM"; return 1 ;;
  esac
  printf 'gh mentions: %s\n' "$([ "$CFG_ENABLED" = true ] && echo on || echo 'off (enabled=false)')"
  printf 'authorized logins:\n'
  cursor_read > "$TMP_STATUS"
  grants_describe "$TMP_STATUS" "$(now_iso)" | sed 's/^/  /'
  printf 'markers: %s\n' "$(printf '%s\n' "$CFG_MARKERS" | paste -sd, -)"
  printf 'requested watcher interval: %ss\n' "$CFG_INTERVAL"
  unwatched_projects | sed 's/^/unwatched: /'
  repos=$(watched_repos)
  if [ -z "$repos" ]; then
    printf 'watched repositories: none - nothing to watch until a project is registered here or a repo is listed in config/gh-mentions.json\n'
  else
    printf 'watched repositories:\n'
    printf '%s\n' "$repos" | sed 's/^/  /'
  fi
  if [ -d "$INBOX" ]; then
    pending=$(find "$INBOX" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  fi
  printf 'pending mentions: %s\n' "$pending"
  printf 'armed: %s\n' "$(fm_custom_check_registered "$STATE" "$CHECK_ID" && echo yes || echo no)"
}

# The cadence this plane asks the home's watcher for, or nothing when it is off.
# bin/fm-bootstrap.sh owns config/x-mode.env and reconciles this request with
# Relay's; this plane never writes a cadence or runs a timer of its own.
action_cadence() {
  local rc=0
  config_load || rc=$?
  [ "$rc" -eq 0 ] || return 0
  [ "$CFG_ENABLED" = true ] || return 0
  [ -n "$(watched_repos)" ] || return 0
  printf '%s\n' "$CFG_INTERVAL"
}

action_arm() {
  local rc=0
  config_load || rc=$?
  case "$rc" in
    1) printf 'fm-gh-mention: no config/gh-mentions.json; nothing to arm\n' >&2; return 1 ;;
    2) printf 'fm-gh-mention: %s\n' "$CONFIG_PROBLEM" >&2; return 1 ;;
  esac
  if [ "$CFG_ENABLED" != true ]; then
    printf 'fm-gh-mention: config/gh-mentions.json has enabled=false; nothing to arm\n' >&2
    return 1
  fi
  fm_check_shim_arm "$STATE" "$CHECK_ID" "$SCRIPT_DIR/fm-gh-mention.sh" \
    'GitHub mention poll shim' "$FM_HOME" || return 1
  unwatched_projects | while IFS= read -r line; do say "$line"; done
  [ -n "$(watched_repos)" ] \
    || say 'nothing to watch yet - no project registered here resolves to a GitHub repository and config/gh-mentions.json lists no repos'
}

# The read cursor survives a disarm on purpose: re-arming then resumes where
# the plane left off instead of re-reading a backfill window and re-filing
# mentions the home has already seen. What was already reported does not
# survive, so a condition still standing at the re-arm is reported again.
action_disarm() {
  fm_check_shim_disarm "$STATE" "$CHECK_ID" "$REPORT_RECORD"
}

trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM

case "${1:-check}" in
  poll|check) action_poll ;;
  pending) action_pending ;;
  ack) shift; action_ack "$@" ;;
  status) action_status ;;
  cadence) action_cadence ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die "unknown action: $1" ;;
esac
