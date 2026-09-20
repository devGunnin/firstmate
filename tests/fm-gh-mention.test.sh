#!/usr/bin/env bash
# Behavior tests for bin/fm-gh-mention.sh, the GitHub mention plane.
#
# Every case drives the real executable against a scratch home whose config,
# project clones and fake `gh` decide the outcome, so the safety core is
# exercised the way the watcher exercises it. Nothing here reads the script's
# own source, and no case contacts github.com.
#
# The fake `gh` serves one canned listing per repository and endpoint from
# $FM_TEST_GH_DIR and records the API paths it was asked for, which is how the
# "never reads an unwatched repo" and "three reads per repo" properties are
# asserted through the interface rather than by inspecting internals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLANE="$ROOT/bin/fm-gh-mention.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-mention)
FAKEBIN="$TMP_ROOT/fakebin"

mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh for the mention plane's tests: canned listings plus a request log.
for arg in "$@"; do last=$arg; done
path=${last%%\?*}
printf '%s\n' "$path" >> "$FM_TEST_GH_DIR/paths.log"
case "$path" in
  */issues/comments) kind=comments ;;
  */pulls/comments) kind=review ;;
  */issues) kind=issues ;;
  *) printf '[]\n'; exit 0 ;;
esac
repo=$(printf '%s' "$path" | sed -n 's|^repos/\([^/]*\)/\([^/]*\)/.*|\1__\2|p')
[ -f "$FM_TEST_GH_DIR/fail" ] && exit 1
if [ -f "$FM_TEST_GH_DIR/$repo.$kind.json" ]; then
  cat "$FM_TEST_GH_DIR/$repo.$kind.json"
else
  printf '[]\n'
fi
FAKE
chmod +x "$FAKEBIN/gh"

# make_home <name> [config-json]: a scratch home, optionally already configured.
make_home() {
  local name=$1 config=${2-} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/gh"
  [ -z "$config" ] || printf '%s\n' "$config" > "$home/config/gh-mentions.json"
  printf '%s\n' "$home"
}

# canned <home> <owner/name> <endpoint> <json>: what the fake gh serves.
canned() {
  local home=$1 repo=$2 kind=$3 json=$4
  printf '%s\n' "$json" > "$home/gh/${repo%/*}__${repo#*/}.$kind.json"
}

# comment <id> <login> <body> <html-url>: one listing entry in GitHub's shape.
comment() {
  jq -nc --argjson id "$1" --arg login "$2" --arg body "$3" --arg url "$4" \
    '{id:$id,user:{login:$login},body:$body,html_url:$url,updated_at:"2026-09-20T10:00:00Z"}'
}

run_plane() {  # <home> <action...>
  local home=$1
  shift
  FM_TEST_GH_DIR="$home/gh" FM_HOME="$home" PATH="$FAKEBIN:$PATH" "$PLANE" "$@"
}

DEFAULT_CONFIG='{"enabled":true,"trusted_logins":["devGunnin","mengsig"],"repos":["owner/demo"],"may_open_pr":true}'

records_in() { find "$1/state/gh-mention-inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
# field <record-file> <jq-path>: read one recorded field through jq, so a case
# asserts the record's contract rather than its formatting.
field() { jq -r "$2" "$1"; }
wakes_in() { grep -c 'check: gh-mention' "$1/state/.wake-queue" 2>/dev/null || printf '0\n'; }

test_help_and_usage() {
  local out rc=0
  out=$("$PLANE" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  for action in poll pending ack status arm disarm; do
    assert_contains "$out" "fm-gh-mention.sh $action" "--help lists the $action action"
  done
  rc=0
  out=$("$PLANE" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown action must exit 2"
  assert_contains "$out" "unknown action" "an unknown action is refused loudly"
  pass "fm-gh-mention: help and usage plumbing"
}

test_absent_config_is_completely_inert() {
  local home out rc=0
  home=$(make_home inert)
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "an unconfigured poll must exit 0"
  [ -z "$out" ] || fail "an unconfigured poll must print nothing: $out"
  assert_absent "$home/state/gh-mention-inbox" "an unconfigured poll creates no inbox"
  assert_absent "$home/state/gh-mention-cursor.json" "an unconfigured poll creates no cursor"
  assert_absent "$home/state/.wake-queue" "an unconfigured poll queues no wake"
  assert_absent "$home/gh/paths.log" "an unconfigured poll makes no forge read"
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "gh mentions: off" "status names the plane as off without a config"
  pass "fm-gh-mention: an absent config leaves the plane completely inert"
}

test_malformed_config_stops_the_plane_loudly() {
  local home out rc=0
  home=$(make_home malformed 'this is not json')
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "is not valid JSON" "a malformed config is reported by the poll"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals '' "$out" "a config that stays malformed is not re-reported every cycle"
  assert_absent "$home/gh/paths.log" "a malformed config makes no forge read"
  assert_absent "$home/state/gh-mention-inbox" "a malformed config files no record"
  out=$(run_plane "$home" status 2>&1) || rc=$?
  expect_code 1 "$rc" "status must fail on a malformed config"
  assert_contains "$out" "stopped" "status reports the plane as stopped"
  rc=0
  out=$(run_plane "$home" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a malformed config"
  assert_absent "$home/state/gh-mention.check.sh" "a refused arm writes no shim"
  pass "fm-gh-mention: a malformed config stops the plane instead of guessing a default"
}

test_unknown_config_key_is_refused() {
  local home out
  home=$(make_home typo '{"enabled":true,"trusted_login":["devGunnin"]}')
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "unknown key" "a mistyped trust list is named, not silently ignored"
  assert_contains "$out" "trusted_login" "the refusal names the offending key"
  pass "fm-gh-mention: a mistyped configuration key is refused rather than ignored"
}

test_a_trusted_marked_comment_is_accepted_once() {
  local home out record
  home=$(make_home accept "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 11 DevGunnin 'hey @firstmate please look at this' \
      'https://github.com/owner/demo/issues/5#issuecomment-11')]"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "record comment-11" "the poll names the record it filed"
  assert_equals 1 "$(records_in "$home")" "exactly one record is filed"
  assert_equals 1 "$(wakes_in "$home")" "exactly one durable wake is queued"
  assert_grep "check: gh-mention comment-11" "$home/state/.wake-queue" "the wake carries the record id"
  record="$home/state/gh-mention-inbox/comment-11.json"
  assert_equals 'owner/demo' "$(field "$record" .repository)" "the record carries its repository"
  assert_equals 'issue' "$(field "$record" .subject_type)" "the record carries the subject type"
  assert_equals 'https://github.com/owner/demo/issues/5' "$(field "$record" .subject_url)" \
    "the record carries the subject URL"
  assert_equals 5 "$(field "$record" .subject_number)" "the record carries the subject number"
  assert_equals 'DevGunnin' "$(field "$record" .author)" "the record carries the trusted author"
  assert_equals '@firstmate' "$(field "$record" .marker)" "the record carries the matched marker"
  assert_equals 11 "$(field "$record" .comment_id)" "the record carries the comment identity"
  assert_equals 'https://github.com/owner/demo/issues/5#issuecomment-11' \
    "$(field "$record" .comment_url)" "the record carries the comment URL"
  assert_contains "$(field "$record" .body)" 'please look at this' "the record carries the comment body"
  assert_not_equals 'null' "$(field "$record" .accepted_at)" "the record carries the time it was accepted"
  pass "fm-gh-mention: a trusted, marked comment is accepted into one record and one wake"
}

test_an_untrusted_author_with_a_marker_is_ignored() {
  local home out
  home=$(make_home untrusted "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 21 stranger '@firstmate ship this for me' \
      'https://github.com/owner/demo/issues/5#issuecomment-21')]"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "an untrusted marked comment must be ignored silently: $out"
  assert_equals 0 "$(records_in "$home")" "an untrusted author files no record"
  assert_equals 0 "$(wakes_in "$home")" "an untrusted author queues no wake"
  pass "fm-gh-mention: a marker from an untrusted account is ignored"
}

test_a_trusted_author_without_a_marker_is_ignored() {
  local home out
  home=$(make_home unmarked "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 31 mengsig 'looks good to me, merging tomorrow' \
      'https://github.com/owner/demo/pull/7#issuecomment-31')]"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "an unmarked comment must be ignored silently: $out"
  assert_equals 0 "$(records_in "$home")" "ordinary conversation by a trusted account files no record"
  pass "fm-gh-mention: a trusted account's ordinary comment is ignored without a marker"
}

test_a_quoted_marker_never_qualifies_on_its_own() {
  local home out
  home=$(make_home quoted "$DEFAULT_CONFIG")
  # The marker text is present, but the body's own author is untrusted; quoting
  # a trusted account must not lend that comment the trusted account's standing.
  canned "$home" owner/demo comments \
    "[$(comment 41 stranger '> devGunnin wrote: @firstmate fix the parser

+1 to that' 'https://github.com/owner/demo/issues/9#issuecomment-41')]"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "a quoted marker must not qualify: $out"
  assert_equals 0 "$(records_in "$home")" "text quoted from a trusted account files no record"
  pass "fm-gh-mention: a marker quoted inside an untrusted comment never qualifies"
}

test_a_repeated_poll_does_not_duplicate_the_record() {
  local home
  home=$(make_home repeat "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 51 mengsig '@captain please investigate' \
      'https://github.com/owner/demo/issues/3#issuecomment-51')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(records_in "$home")" "the first poll files the record"
  [ -z "$(run_plane "$home" poll 2>&1)" ] || fail "a repeated poll must stay silent"
  assert_equals 1 "$(records_in "$home")" "a repeated poll does not duplicate the record"
  assert_equals 1 "$(wakes_in "$home")" "a repeated poll does not duplicate the wake"
  pass "fm-gh-mention: a repeated poll re-derives the same mention without duplicating it"
}

test_ack_moves_the_record_into_handled() {
  local home out
  home=$(make_home ack "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 61 mengsig '@firstmate review this' \
      'https://github.com/owner/demo/pull/8#issuecomment-61')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_contains "$(run_plane "$home" pending)" 'comment-61' "pending lists the unhandled record"
  out=$(run_plane "$home" ack comment-61 2>&1)
  assert_contains "$out" "acked comment-61" "ack names the record it acknowledged"
  assert_absent "$home/state/gh-mention-inbox/comment-61.json" "ack clears the pending record"
  assert_present "$home/state/gh-mention-inbox/handled/comment-61.json" "ack keeps the record under handled/"
  assert_contains "$(run_plane "$home" ack comment-61 2>&1)" "already-acked" "a repeated ack is a no-op"
  assert_equals '[]' "$(run_plane "$home" pending | tr -d ' \n')" "nothing stays pending after ack"
  pass "fm-gh-mention: ack moves a handled record out of the pending inbox"
}

test_an_unwatched_repo_is_never_read() {
  local home out
  home=$(make_home unwatched "$DEFAULT_CONFIG")
  canned "$home" other/elsewhere comments \
    "[$(comment 71 devGunnin '@firstmate do this' \
      'https://github.com/other/elsewhere/issues/1#issuecomment-71')]"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "an unwatched repo must produce nothing: $out"
  assert_equals 0 "$(records_in "$home")" "a mention in an unwatched repo files no record"
  assert_no_grep 'other/elsewhere' "$home/gh/paths.log" "an unwatched repo is never read at all"
  pass "fm-gh-mention: a qualifying mention in an unwatched repository is never read"
}

test_every_watched_repo_makes_progress_at_a_constant_cost() {
  local home out repo id=200
  home=$(make_home many \
    '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/one","o/two","o/three"]}')
  for repo in one two three; do
    id=$((id + 1))
    canned "$home" "o/$repo" comments \
      "[$(comment "$id" mengsig "@firstmate handle $repo" \
        "https://github.com/o/$repo/issues/1#issuecomment-$id")]"
  done
  out=$(run_plane "$home" poll 2>&1)
  assert_equals 3 "$(records_in "$home")" "each watched repo files its own record"
  for repo in one two three; do
    assert_contains "$out" "https://github.com/o/$repo/issues/1" "the poll reports the mention in o/$repo"
    assert_equals 3 "$(grep -c "^repos/o/$repo/" "$home/gh/paths.log")" \
      "o/$repo costs exactly three reads per poll"
  done
  assert_equals 3 "$(jq -r '.repos | length' "$home/state/gh-mention-cursor.json")" \
    "every watched repo carries its own cursor"
  pass "fm-gh-mention: every watched repo makes progress at a constant three reads per poll"
}

test_the_least_recently_read_repo_goes_first() {
  local home first
  home=$(make_home order '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/fresh","o/stale"]}')
  jq -n '{schema:"fm-gh-mention-cursor.v1",
          repos:{"o/fresh":"2026-09-20T11:00:00Z"},processed:[]}' \
    > "$home/state/gh-mention-cursor.json"
  run_plane "$home" poll >/dev/null 2>&1
  first=$(sed -n '1p' "$home/gh/paths.log")
  assert_contains "$first" "repos/o/stale/" "the repo with no cursor is read before the freshly read one"
  pass "fm-gh-mention: the least recently read repository is polled first"
}

test_a_registered_project_contributes_its_github_origin() {
  local home out
  home=$(make_home registry '{"enabled":true,"trusted_logins":["mengsig"]}')
  mkdir -p "$home/data" "$home/projects/demo"
  printf '%s\n' '# Projects' '' '- demo [no-mistakes] - the demo project (added 2026-09-20)' \
    > "$home/data/projects.md"
  git -C "$home/projects/demo" init -q
  git -C "$home/projects/demo" remote add origin https://github.com/owner/demo.git
  canned "$home" owner/demo comments \
    "[$(comment 81 mengsig '@firstmate look here' \
      'https://github.com/owner/demo/issues/2#issuecomment-81')]"
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "owner/demo" "a registered project's clone origin becomes a watched repo"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-81.json" \
    "a mention in a registered project's repo is accepted"
  pass "fm-gh-mention: a registered project's clone contributes its GitHub origin to the watched set"
}

test_an_unresolvable_project_is_reported_not_dropped() {
  local home out
  home=$(make_home noclone '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/one"]}')
  mkdir -p "$home/data"
  printf '%s\n' '- ghost - a project with no clone here (added 2026-09-20)' \
    > "$home/data/projects.md"
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "ghost" "status names the registered project it cannot watch"
  assert_contains "$out" "no clone here" "status says why that project is not watched"
  pass "fm-gh-mention: a registered project that resolves to no repository is reported"
}

test_an_empty_watched_set_says_there_is_nothing_to_watch() {
  local home out
  home=$(make_home empty '{"enabled":true,"trusted_logins":["mengsig"]}')
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "nothing to watch" "status says plainly that there is nothing to watch"
  out=$(run_plane "$home" arm 2>&1)
  assert_contains "$out" "nothing to watch" "arming says plainly that there is nothing to watch"
  assert_present "$home/state/gh-mention.check.sh" "the shim is still armed for repos registered later"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "a poll with nothing to watch must stay silent: $out"
  assert_absent "$home/gh/paths.log" "a poll with nothing to watch makes no forge read"
  pass "fm-gh-mention: an empty watched set is reported rather than polled silently"
}

test_arm_binds_the_shim_and_disarm_removes_it() {
  local home out
  home=$(make_home arming "$DEFAULT_CONFIG")
  run_plane "$home" poll >/dev/null 2>&1
  out=$(run_plane "$home" arm 2>&1)
  assert_contains "$out" "armed: state/gh-mention.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/gh-mention.check.sh" "arm writes the check shim"
  assert_present "$home/state/gh-mention.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/gh-mention.check.sh")" "fm-gh-mention.sh check" \
    "the shim dispatches the poll"
  assert_contains "$(cat "$home/state/gh-mention.check.sh")" "FM_HOME=$home" \
    "the shim pins the absolute home"
  out=$(run_plane "$home" arm 2>&1)
  assert_contains "$out" "armed" "re-arming stays armed"
  assert_contains "$(run_plane "$home" status 2>&1)" "armed: yes" "status reports the armed plane"
  : > "$home/gh/fail"
  run_plane "$home" poll >/dev/null 2>&1
  rm -f "$home/gh/fail"
  assert_present "$home/state/gh-mention.reported" "a reported failure is recorded"
  out=$(run_plane "$home" disarm 2>&1)
  assert_contains "$out" "disarmed" "disarm names what it retired"
  assert_absent "$home/state/gh-mention.check.sh" "disarm removes the shim"
  assert_absent "$home/state/gh-mention.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/gh-mention.reported" \
    "disarm forgets what was reported so a standing condition is reported again after a re-arm"
  assert_present "$home/state/gh-mention-cursor.json" \
    "disarm keeps the read cursor so a re-arm resumes where the plane left off"
  pass "fm-gh-mention: arm writes and binds the shim, and disarm removes every trace"
}

test_a_disabled_config_arms_nothing() {
  local home out rc=0
  home=$(make_home disabled '{"enabled":false,"trusted_logins":["mengsig"],"repos":["o/one"]}')
  canned "$home" o/one comments \
    "[$(comment 91 mengsig '@firstmate do this' 'https://github.com/o/one/issues/1#issuecomment-91')]"
  out=$(run_plane "$home" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a disabled plane"
  assert_contains "$out" "enabled=false" "the refusal names the disabled setting"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "a disabled poll must stay silent: $out"
  assert_absent "$home/gh/paths.log" "a disabled poll makes no forge read"
  pass "fm-gh-mention: a disabled config arms nothing and reads nothing"
}

test_review_comments_and_bodies_qualify_too() {
  local home
  home=$(make_home kinds "$DEFAULT_CONFIG")
  canned "$home" owner/demo review \
    "[$(comment 101 mengsig '@firstmate this line is wrong' \
      'https://github.com/owner/demo/pull/4#discussion_r101')]"
  canned "$home" owner/demo issues \
    "[$(comment 102 devGunnin '@captain please triage this issue' \
      'https://github.com/owner/demo/issues/12')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/review-comment-101.json" "a PR review comment qualifies"
  assert_present "$home/state/gh-mention-inbox/issue-102.json" "an issue or PR body qualifies"
  assert_equals pull "$(field "$home/state/gh-mention-inbox/review-comment-101.json" .subject_type)" \
    "a review comment resolves to its pull request"
  assert_equals body "$(field "$home/state/gh-mention-inbox/issue-102.json" .comment_kind)" \
    "a subject body is recorded as a body"
  pass "fm-gh-mention: review comments and issue or PR bodies qualify alongside comments"
}

test_a_plain_login_entry_is_a_permanent_authorization() {
  local home
  home=$(make_home permanent "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 301 mengsig '@firstmate one' 'https://github.com/owner/demo/issues/1#issuecomment-301')]"
  run_plane "$home" poll >/dev/null 2>&1
  canned "$home" owner/demo comments \
    "[$(comment 302 mengsig '@firstmate two' 'https://github.com/owner/demo/issues/1#issuecomment-302')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 2 "$(records_in "$home")" "a plain login keeps qualifying with no bound to spend"
  assert_equals '{}' "$(jq -c '.grants // {}' "$home/state/gh-mention-cursor.json")" \
    "a plain login spends nothing"
  assert_contains "$(run_plane "$home" status)" "mengsig - permanent" \
    "status names a plain login as a permanent authorization"
  pass "fm-gh-mention: a plain login entry stays a permanent authorization"
}

test_an_expiry_in_the_past_never_qualifies() {
  local home out
  home=$(make_home expired \
    '{"enabled":true,"trusted_logins":[{"login":"guest","until":"2020-01-01T00:00:00Z"}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 311 guest '@firstmate please look' 'https://github.com/o/r/issues/1#issuecomment-311')]"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals 0 "$(records_in "$home")" "an expired authorization files no record"
  assert_equals 0 "$(wakes_in "$home")" "an expired authorization queues no wake"
  assert_contains "$out" "has lapsed" "the lapsed authorization is reported"
  assert_contains "$out" "expired at 2020-01-01T00:00:00Z" "the report names the expiry it passed"
  pass "fm-gh-mention: an authorization whose expiry has passed never qualifies"
}

test_a_count_bounded_grant_stops_at_zero() {
  local home out id=400
  home=$(make_home counted \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":2}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 401 guest '@firstmate first' 'https://github.com/o/r/issues/1#issuecomment-401'),
      $(comment 402 guest '@firstmate second' 'https://github.com/o/r/issues/2#issuecomment-402'),
      $(comment 403 guest '@firstmate third' 'https://github.com/o/r/issues/3#issuecomment-403')]"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals 2 "$(records_in "$home")" "a grant of two funds exactly two accepted mentions"
  assert_absent "$home/state/gh-mention-inbox/comment-403.json" \
    "the mention past the bound is refused inside the same poll"
  assert_equals 2 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "the spend is recorded durably, once per accepted mention"
  pass "fm-gh-mention: a count-bounded authorization stops qualifying at zero"
}

test_the_count_decrements_only_on_acceptance() {
  local home
  home=$(make_home spend-once \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":5}],"repos":["o/r"]}')
  # One qualifying comment, plus two that are scanned but never accepted: an
  # unmarked comment from the same account, and a marked one from a stranger.
  canned "$home" o/r comments \
    "[$(comment 411 guest '@firstmate do this' 'https://github.com/o/r/issues/1#issuecomment-411'),
      $(comment 412 guest 'just chatting' 'https://github.com/o/r/issues/1#issuecomment-412'),
      $(comment 413 stranger '@firstmate do this too' 'https://github.com/o/r/issues/1#issuecomment-413')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(records_in "$home")" "only the qualifying comment is accepted"
  assert_equals 1 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "the count spends once per accepted mention, not per comment scanned"
  # A second poll re-scans the same comments and must not spend again.
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "a repeated poll over the same comments spends nothing further"
  pass "fm-gh-mention: a bounded count decrements only on an accepted mention"
}

test_a_lapsed_grant_is_reported_once() {
  local home out
  home=$(make_home lapse-once \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":1}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 421 guest '@firstmate only one' 'https://github.com/o/r/issues/1#issuecomment-421')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(records_in "$home")" "the single authorized request is accepted"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "has lapsed" "the exhausted authorization is reported when it lapses"
  out=$(run_plane "$home" poll 2>&1)
  assert_not_contains "$out" "has lapsed" "a lapsed authorization is reported once, not every poll"
  # Renewing it makes it live again, and reportable again if it lapses later.
  printf '%s\n' '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":2}],"repos":["o/r"]}' \
    > "$home/config/gh-mentions.json"
  canned "$home" o/r comments \
    "[$(comment 422 guest '@firstmate renewed' 'https://github.com/o/r/issues/2#issuecomment-422')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-422.json" "a renewed authorization qualifies again"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "has lapsed" "a renewed authorization is reportable again once it lapses"
  pass "fm-gh-mention: a lapsed authorization is reported once and again after renewal"
}

test_a_retried_mention_is_never_charged_twice() {
  local home
  home=$(make_home recharge \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":2}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 441 guest '@firstmate once' 'https://github.com/o/r/issues/1#issuecomment-441')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "the accepted mention is charged once"
  # A poll that died after charging but before remembering the mention leaves
  # exactly this state; the retry must re-derive the same mention and charge
  # nothing further, or a crash would quietly spend a bounded trial twice.
  jq '.repos = {} | .processed = []' "$home/state/gh-mention-cursor.json" > "$home/c.json"
  mv "$home/c.json" "$home/state/gh-mention-cursor.json"
  rm -f "$home/state/gh-mention-inbox"/*.json
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-441.json" "the retry re-files the same mention"
  assert_equals 1 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "a retried mention is charged once, not twice"
  assert_contains "$(run_plane "$home" status)" "1 of 2 requests left" \
    "the grant still has its second request"
  pass "fm-gh-mention: a retried mention is never charged to a grant twice"
}

test_an_unspendable_bound_refuses_the_mention() {
  local home out
  home=$(make_home unspendable \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":3}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 431 guest '@firstmate urgent' 'https://github.com/o/r/issues/1#issuecomment-431')]"
  # A cursor the plane refuses to write through - here a symlink out of the
  # state directory - means the spend cannot be made durable. Accepting anyway
  # would act on a bound nobody can verify, so the mention must be refused.
  mkdir -p "$home/elsewhere"
  jq -n '{schema:"fm-gh-mention-cursor.v1",repos:{},processed:[],grants:{},lapsed:[]}' \
    > "$home/elsewhere/cursor.json"
  ln -s "$home/elsewhere/cursor.json" "$home/state/gh-mention-cursor.json"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals 0 "$(records_in "$home")" "a spend that cannot be made durable accepts nothing"
  assert_equals 0 "$(wakes_in "$home")" "a refused spend queues no wake"
  assert_contains "$out" "not accepted" "the refusal says the mention was not accepted"
  assert_equals 0 "$(jq -r '(.grants.guest.spent_on // []) | length' "$home/elsewhere/cursor.json")" \
    "a refused spend leaves the grant untouched"
  pass "fm-gh-mention: a bound that cannot be durably spent refuses the mention"
}

test_a_malformed_grant_is_refused() {
  local home out
  home=$(make_home badgrant '{"enabled":true,"trusted_logins":[{"login":"guest","until":"whenever"}]}')
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" 'not an ISO 8601 timestamp' "an unreadable expiry stops the plane"
  home=$(make_home badcount '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":-2}]}')
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" 'not a whole number of requests' "an unreadable count stops the plane"
  pass "fm-gh-mention: a malformed bound stops the plane instead of being ignored"
}

test_the_plane_requests_a_fast_watcher_cadence() {
  local home
  home=$(make_home cadence "$DEFAULT_CONFIG")
  assert_equals 30 "$(run_plane "$home" cadence)" "an enabled plane asks for the default fast cadence"
  printf '%s\n' '{"enabled":true,"trusted_logins":["mengsig"],"repos":["owner/demo"],"check_interval":90}' \
    > "$home/config/gh-mentions.json"
  assert_equals 90 "$(run_plane "$home" cadence)" "a configured interval is what the plane asks for"
  assert_contains "$(run_plane "$home" status)" "requested watcher interval: 90s" \
    "status reports the interval this plane asks for"
  printf '%s\n' '{"enabled":false,"trusted_logins":["mengsig"],"repos":["owner/demo"]}' \
    > "$home/config/gh-mentions.json"
  assert_equals '' "$(run_plane "$home" cadence)" "a disabled plane asks for no speed-up"
  printf '%s\n' '{"enabled":true,"trusted_logins":["mengsig"],"check_interval":5}' \
    > "$home/config/gh-mentions.json"
  assert_contains "$(run_plane "$home" poll 2>&1)" 'from 10 to 300' \
    "an out-of-range interval stops the plane rather than being clamped"
  pass "fm-gh-mention: the plane requests a configured fast watcher cadence"
}

test_a_full_page_stops_the_cursor_where_the_read_stopped() {
  local home page cursor
  home=$(make_home paged '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/busy"]}')
  # A repo with more new activity than one page holds: the listing comes back
  # full, so the cursor must stop at the last moment actually read instead of
  # jumping to now and stepping over everything the page cut off.
  page=$(jq -nc '[range(100) | {id:(500 + .),user:{login:"mengsig"},
    body:"@firstmate item \(.)",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-\(500 + .)",
    updated_at:"2026-09-19T0\(. % 10):00:00Z"}]')
  canned "$home" o/busy comments "$page"
  run_plane "$home" poll >/dev/null 2>&1
  cursor=$(jq -r '.repos["o/busy"]' "$home/state/gh-mention-cursor.json")
  assert_equals '2026-09-19T09:00:00Z' "$cursor" \
    "a full page leaves the cursor at the last entry it actually read"
  pass "fm-gh-mention: a full listing page stops the cursor where the read stopped"
}

test_a_failed_read_keeps_the_repo_cursor() {
  local home out before
  home=$(make_home failing "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 111 mengsig '@firstmate urgent' \
      'https://github.com/owner/demo/issues/1#issuecomment-111')]"
  run_plane "$home" poll >/dev/null 2>&1
  before=$(jq -r '.repos["owner/demo"]' "$home/state/gh-mention-cursor.json")
  : > "$home/gh/fail"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "could not read owner/demo" "a failed read is reported, not swallowed"
  assert_equals "$before" "$(jq -r '.repos["owner/demo"]' "$home/state/gh-mention-cursor.json")" \
    "a repo whose read failed keeps its cursor so nothing is skipped"
  pass "fm-gh-mention: a repository whose read fails keeps its cursor and is reported"
}

# The watcher wakes firstmate on ANY output from this check, so a condition that
# outlives one poll must be reported once rather than on every cycle.
test_a_persistent_failure_is_reported_once() {
  local home out
  home=$(make_home repeat "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 222 mengsig '@firstmate urgent' \
      'https://github.com/owner/demo/issues/2#issuecomment-222')]"
  run_plane "$home" poll >/dev/null 2>&1
  : > "$home/gh/fail"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "could not read owner/demo" "the first poll of a new failure reports it"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals '' "$out" \
    "a failure that persists must stay silent instead of waking the supervisor every cycle"
  rm -f "$home/gh/fail"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals '' "$out" "a recovered repo with nothing new says nothing"
  : > "$home/gh/fail"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "could not read owner/demo" \
    "a failure that returns after clearing is reported again"
  pass "fm-gh-mention: a persistent failure is reported once, and again only if it returns"
}

# A mention that qualified but could not be filed must be genuinely re-derived,
# which only happens if its repo's cursor does not step over the window it was in.
test_an_unfiled_mention_keeps_the_repo_cursor() {
  local home out
  home=$(make_home unfiled "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 333 mengsig '@firstmate please look' \
      'https://github.com/owner/demo/issues/3#issuecomment-333')]"
  mkdir -p "$home/state/gh-mention-inbox"
  ln -s "$home/state/elsewhere.json" "$home/state/gh-mention-inbox/comment-333.json"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "could not file a mention" "a mention that cannot be filed is reported"
  assert_absent "$home/state/elsewhere.json" "a linked record destination is never written through"
  assert_equals 0 "$(wakes_in "$home")" "an unfiled mention queues no wake"
  assert_equals null \
    "$(jq -r '.repos["owner/demo"] // "null"' "$home/state/gh-mention-cursor.json")" \
    "a repo holding an unfiled mention must not advance past the window it was in"
  rm -f "$home/state/gh-mention-inbox/comment-333.json"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-333.json" \
    "the unfiled mention is re-derived and filed once it can be written"
  assert_equals 1 "$(wakes_in "$home")" "the re-derived mention queues its wake"
  pass "fm-gh-mention: a mention that could not be filed is re-derived rather than lost"
}

test_opening_a_pull_request_is_consented_unless_withheld() {
  local home out
  home=$(make_home consent-default '{"enabled":true,"trusted_logins":["mengsig"]}')
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "may open pr: true" \
    "the minimal configuration carries the trusted tag's consent to open a pull request"
  home=$(make_home consent-withheld \
    '{"enabled":true,"trusted_logins":["mengsig"],"may_open_pr":false}')
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "may open pr: false" \
    "a home that deliberately withholds pull-request opening still can"
  pass "fm-gh-mention: opening a pull request is consented unless deliberately withheld"
}

test_help_and_usage
test_absent_config_is_completely_inert
test_malformed_config_stops_the_plane_loudly
test_unknown_config_key_is_refused
test_a_trusted_marked_comment_is_accepted_once
test_an_untrusted_author_with_a_marker_is_ignored
test_a_trusted_author_without_a_marker_is_ignored
test_a_quoted_marker_never_qualifies_on_its_own
test_a_repeated_poll_does_not_duplicate_the_record
test_ack_moves_the_record_into_handled
test_an_unwatched_repo_is_never_read
test_every_watched_repo_makes_progress_at_a_constant_cost
test_the_least_recently_read_repo_goes_first
test_a_registered_project_contributes_its_github_origin
test_an_unresolvable_project_is_reported_not_dropped
test_an_empty_watched_set_says_there_is_nothing_to_watch
test_arm_binds_the_shim_and_disarm_removes_it
test_a_disabled_config_arms_nothing
test_review_comments_and_bodies_qualify_too
test_a_plain_login_entry_is_a_permanent_authorization
test_an_expiry_in_the_past_never_qualifies
test_a_count_bounded_grant_stops_at_zero
test_the_count_decrements_only_on_acceptance
test_a_lapsed_grant_is_reported_once
test_a_retried_mention_is_never_charged_twice
test_an_unspendable_bound_refuses_the_mention
test_a_malformed_grant_is_refused
test_the_plane_requests_a_fast_watcher_cadence
test_a_full_page_stops_the_cursor_where_the_read_stopped
test_a_failed_read_keeps_the_repo_cursor
test_a_persistent_failure_is_reported_once
test_an_unfiled_mention_keeps_the_repo_cursor
test_opening_a_pull_request_is_consented_unless_withheld
