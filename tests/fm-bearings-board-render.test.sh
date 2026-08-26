#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

# Build the board from <charted-json> and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 charted=$2 more=${3:-0} warning_more=${4:-0} data="$1/payload.json"
  jq -n --argjson charted "$charted" --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board with <usage-json> ("null" omits the field) and render it.
render_usage() {  # <home> <usage-json> [tz]
  local home=$1 usage=$2 tz=${3:-UTC} data="$1/payload.json"
  jq -n --argjson usage "$usage" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[], charted:[]}
    + (if $usage == null then {} else {claude_usage:$usage} end)' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  TZ="$tz" node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}


test_both_usage_bars_render_with_their_percent_used() {
  local home out
  home=$(make_home usage-both)
  out=$(render_usage "$home" '{"session":{"percent_used":42,"resets_at":"2026-08-26T18:00:00Z"},"week":{"percent_used":71}}')
  printf '%s' "$out" | jq -e '
    .usage.hidden == false
      and ([.usage.items[].label] == ["session", "week"])
      and (.usage.items[0] | .pct == "42% used" and .unknown == false and (.fill | test("42%")))
      and (.usage.items[1] | .pct == "71% used" and .unknown == false and (.fill | test("71%")))
  ' >/dev/null || fail "the usage bars did not render both windows: $out"
  pass "the session and week bars render their percent used and a proportional fill"
}

test_the_session_bar_shows_its_reset_in_the_viewers_local_time() {
  local home out_tokyo out_utc
  home=$(make_home usage-reset)
  out_tokyo=$(render_usage "$home" '{"session":{"percent_used":10,"resets_at":"2026-08-26T18:00:00Z"},"week":{"percent_used":20}}' Asia/Tokyo)
  out_utc=$(render_usage "$home" '{"session":{"percent_used":10,"resets_at":"2026-08-26T18:00:00Z"},"week":{"percent_used":20}}' UTC)
  printf '%s' "$out_tokyo" | jq -e '
    (.usage.items[0].reset | test("^resets .*3:00")) and (.usage.items[1].reset == null)
  ' >/dev/null || fail "the session reset did not render in the viewer local time: $out_tokyo"
  [ "$(printf '%s' "$out_tokyo" | jq -r '.usage.items[0].reset')" \
    != "$(printf '%s' "$out_utc" | jq -r '.usage.items[0].reset')" ] \
    || fail "the same reset instant rendered identically in two time zones: $out_tokyo"
  pass "the session bar shows its reset time converted to the viewer time zone"
}

test_an_unavailable_window_never_reads_as_zero_percent() {
  local home out
  home=$(make_home usage-unavailable)
  out=$(render_usage "$home" '{"session":{"percent_used":null},"week":{}}')
  printf '%s' "$out" | jq -e '
    .usage.hidden == false and ([.usage.items[].label] == ["session", "week"])
      and ([.usage.items[] | .pct] == ["unavailable", "unavailable"])
      and ([.usage.items[] | .unknown] == [true, true])
      and ([.usage.items[] | .fill] == [null, null])
  ' >/dev/null || fail "an unavailable window rendered as a figure: $out"
  pass "a null or missing percent renders an explicit unavailable state, never 0%"
}

test_an_omitted_usage_field_renders_no_widget() {
  local home out
  home=$(make_home usage-absent)
  out=$(render_usage "$home" null)
  printf '%s' "$out" | jq -e '.error == "" and .usage.hidden == true and (.usage.items | length) == 0' \
    >/dev/null || fail "an omitted usage field still produced a widget: $out"
  pass "an omitted usage field renders nothing at all"
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_both_usage_bars_render_with_their_percent_used
test_the_session_bar_shows_its_reset_in_the_viewers_local_time
test_an_unavailable_window_never_reads_as_zero_percent
test_an_omitted_usage_field_renders_no_widget
