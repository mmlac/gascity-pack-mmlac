#!/usr/bin/env bash
#
# patrol-wake — wake a patrol agent whose loop has stopped advancing.
#
# WHY THIS EXISTS (gcs-i31). The witness and the deacon are `mode = "always"`
# named sessions, and buildIdleTracker (gascity cmd/gc/cmd_start.go) exempts
# those from BOTH the idle-timeout and the max-session-age trackers:
# "mode=always must never be subject to idle timeout". So `idle_timeout` in
# their agent.toml is INERT, nothing recycles them, and a patrol loop that
# ends its turn while waiting is simply over — with no symptom but an
# absence. Measured 2026-10-08: the witness went 6.5 h without a cycle while
# the mayor hand-nudged the refinery queue five times.
#
# mol-{witness,deacon}-patrol's next-iteration step was fixed to self-propel,
# but that fix is prose, and prose cannot force a next turn. This order is the
# belt: it runs inline in the controller, so unlike an in-session timer it
# survives every restart, drain and `gc reload` — the same reason
# /gc/orders/mergeguard.toml exists ("mergeguard used to run only as a
# mayor-session shell script, which died with the session").
#
# WHAT IT DOES. Every interval: for each live patrol session, read the newest
# patrol wisp assigned to it and nudge the session if that wisp has not
# advanced within GC_PATROL_WAKE_STALE_AFTER. A healthy loop pours a fresh
# wisp every cycle, so the newest wisp's age IS the time since the cycle
# began. Nudges are rate-limited per episode and escalate to the mayor
# instead of repeating forever.
#
# WHAT IT REFUSES TO DO:
#   - never nudge on an unproven read: a bead-store read that errors is
#     reported as an error and the agent is skipped, never treated as healthy
#     (and the sweep exits non-zero so order health tracking sees it)
#   - never infer the store: a rig agent is read with an explicit --rig, a
#     city agent from the city store, and the store read is logged per agent
#     (a bare `bd` in a city-scope order answers from the CITY store, which is
#     how an earlier sweep examined no rig bead for a week — ex-w2tnph)
#   - never nudge a rig that is suspended, or a session that is not live
#   - never kill or restart anything. A wedged named session is revived by
#     `gc session kill <name>` (the controller re-spawns mode=always), but
#     that discards context, so it stays a human's call.
#
# Exit 0 = the sweep itself ran (including when it nudged). Exit 1 = an
# operational failure of the sweep (missing jq, unreadable session list or
# bead store) — the thing the controller's order health should retry on.
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "patrol-wake: jq is required but not found in PATH" >&2
    exit 1
fi

CITY="${GC_CITY_PATH:-${GC_CITY:-/gc}}"
PACK_STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/mmlac}"
STATE_FILE="$PACK_STATE_DIR/patrol-wake-state.json"
LOG="${GC_PATROL_WAKE_LOG:-$PACK_STATE_DIR/patrol-wake.log}"

# Which agents to watch, matched against the session's template suffix.
# The refinery is deliberately absent: it is mode="on_demand", so its
# idle_timeout=2h is live and the controller recycles it. Add it here if that
# ever changes.
TEMPLATES="${GC_PATROL_WAKE_TEMPLATES:-witness deacon}"
# A healthy cycle is one patrol plus at most idle_floor+idle_budget of waiting
# (~8 min on the formula defaults), so this wants roughly 2x headroom.
STALE_AFTER="${GC_PATROL_WAKE_STALE_AFTER:-20m}"
# Minimum gap between two nudges for the same stall, so a long legitimate
# operation is not nudged every interval.
RENUDGE_AFTER="${GC_PATROL_WAKE_RENUDGE_AFTER:-30m}"
# After this many nudges in one episode, mail the mayor and stop nudging:
# if three immediate nudges did not move it, more will not either.
ESCALATE_AFTER="${GC_PATROL_WAKE_ESCALATE_AFTER:-3}"
MAIL_TARGET="${GC_PATROL_WAKE_MAIL_TARGET:-mayor/}"
DRY_RUN="${GC_PATROL_WAKE_DRY_RUN:-0}"

mkdir -p "$PACK_STATE_DIR"
now_epoch="$(date -u +%s)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
errors=0
nudged=0
examined=0

log() { printf '[%s] %s\n' "$now_iso" "$1" | tee -a "$LOG"; }

# A simple Go-style duration (Ns/Nm/Nh) or a bare number of seconds.
to_seconds() {
    case "$1" in
        *h) echo $(( ${1%h} * 3600 )) ;;
        *m) echo $(( ${1%m} * 60 )) ;;
        *s) echo "${1%s}" ;;
        *)  echo "$1" ;;
    esac
}
stale_s="$(to_seconds "$STALE_AFTER")"
renudge_s="$(to_seconds "$RENUDGE_AFTER")"

[ -s "$STATE_FILE" ] || printf '{}\n' > "$STATE_FILE"
if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    log "WARN state file $STATE_FILE is not valid JSON — starting fresh"
    printf '{}\n' > "$STATE_FILE"
fi

state_get() { jq -r --arg k "$1" --arg f "$2" '(.[$k][$f] // "")' "$STATE_FILE"; }
state_put() {
    local k="$1" ep="$2" n="$3" last="$4" tmp
    tmp="$(mktemp)"
    jq --arg k "$k" --arg ep "$ep" --argjson n "$n" --arg last "$last" \
       '.[$k] = {episode: $ep, nudges: $n, last_nudge: $last}' "$STATE_FILE" > "$tmp" \
       && mv "$tmp" "$STATE_FILE" || rm -f "$tmp"
}
state_clear() {
    local k="$1" tmp
    tmp="$(mktemp)"
    jq --arg k "$k" 'del(.[$k])' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE" || rm -f "$tmp"
}

# --- which rigs are off limits ---------------------------------------------
err="$(mktemp)"; trap 'rm -f "$err"' EXIT
if ! rigs_json="$(gc rig list --json 2>"$err")"; then
    log "ERROR cannot read rig list: $(tr '\n' ' ' < "$err")"
    exit 1
fi
suspended_rigs="$(printf '%s' "$rigs_json" | jq -r '[(.rigs // [])[] | select(.suspended) | .name] | join(" ")')"
[ -n "$suspended_rigs" ] && log "suspended rigs (skipped): $suspended_rigs"

# --- enumerate the live patrol sessions ------------------------------------
# Derived from the session list, never constructed from a name pattern: an
# agent with no session has nothing to wake (the controller owns spawning).
if ! sessions_json="$(gc session list --json --state=all 2>"$err")"; then
    log "ERROR cannot read session list: $(tr '\n' ' ' < "$err")"
    exit 1
fi

suffix_filter="$(printf '%s' "$TEMPLATES" | tr ' ' '\n' | jq -R . | jq -s .)"
rows="$(printf '%s' "$sessions_json" | jq -r --argjson sfx "$suffix_filter" '
  (.sessions // [])[]
  | select((.template // "") as $t | $sfx | any(. as $s | $t | endswith("." + $s)))
  | [ (.name // .id),
      (if (.rig // "") == "" then "-" else .rig end),
      (if (.state // "") == "" then "-" else .state end),
      (.template // "-") ]
  | @tsv')"

if [ -z "$rows" ]; then
    log "no patrol sessions matched templates [$TEMPLATES] — nothing to watch"
    exit 0
fi

while IFS=$'\t' read -r name rig state template; do
    [ -n "$name" ] || continue
    examined=$(( examined + 1 ))
    # jq emits "-" for a city-scope agent: TAB is IFS whitespace, so a real
    # empty field would collapse and shift every column after it.
    [ "$rig" = "-" ] && rig=""

    case " $suspended_rigs " in
        *" $rig "*) log "$name: rig $rig is suspended — skipped"; continue ;;
    esac

    # Only a live session can be woken. Anything the controller or an operator
    # currently owns (draining, drained, suspended, quarantined, creating) is
    # left alone.
    case "$state" in
        active|awake|asleep|idle) : ;;
        *) log "$name: state=$state is not wakeable — skipped"; continue ;;
    esac

    # Name the store. A rig agent's wisps live in that rig's store; the
    # deacon's live in the city store. Never inherit it from cwd.
    if [ -n "$rig" ]; then
        store="rig:$rig"
        beads_json="$(gc bd list --rig "$rig" --assignee="$name" --include-infra --json 2>"$err" </dev/null)"; rc=$?
    else
        store="city"
        beads_json="$(gc bd list --assignee="$name" --include-infra --json 2>"$err" </dev/null)"; rc=$?
    fi
    if [ "$rc" -ne 0 ] || [ -z "$beads_json" ]; then
        log "ERROR $name: cannot read $store store: $(tr '\n' ' ' < "$err") — NOT treated as healthy, not nudged"
        errors=1
        continue
    fi

    newest="$(printf '%s' "$beads_json" | jq -r '
      [ (.[]? // empty)
        | select((.issue_type // "") == "molecule")
        | select((.title // "") | startswith("mol-"))
        | {id, title, updated_at: ((.updated_at // "") | sub("\\.[0-9]+Z$"; "Z"))}
        | select(.updated_at != "") ]
      | sort_by(.updated_at) | last
      | if . == null then "" else "\(.id)\t\(.updated_at)\t\(.title)" end' 2>/dev/null)"

    if [ -z "$newest" ]; then
        # No patrol wisp at all. That can be a real stop (the loop died before
        # pouring) or a momentary window mid-cycle, so it takes two consecutive
        # sightings before it counts — never difference a single observation
        # against an in-flight pour.
        episode="no-wisp"
        if [ "$(state_get "$name" episode)" != "no-wisp" ]; then
            log "$name ($store): no patrol wisp assigned — recorded, will act if it persists"
            state_put "$name" "no-wisp" 0 ""
            continue
        fi
        age_s=$(( stale_s + 1 ))
        wisp="(none)"
        detail="no patrol wisp assigned, twice running"
    else
        wisp="$(printf '%s' "$newest" | cut -f1)"
        updated="$(printf '%s' "$newest" | cut -f2)"
        title="$(printf '%s' "$newest" | cut -f3)"
        updated_epoch="$(printf '%s' "$updated" | jq -Rr 'try fromdateiso8601 catch empty' 2>/dev/null)"
        if [ -z "$updated_epoch" ]; then
            log "ERROR $name ($store): cannot parse updated_at=$updated on $wisp — not nudged"
            errors=1
            continue
        fi
        age_s=$(( now_epoch - updated_epoch ))
        episode="$wisp@$updated"
        detail="$title last advanced ${age_s}s ago (${updated})"
    fi

    if [ "$age_s" -lt "$stale_s" ]; then
        log "$name ($store): OK — $detail"
        [ -n "$(state_get "$name" episode)" ] && state_clear "$name"
        continue
    fi

    prev_episode="$(state_get "$name" episode)"
    prev_nudges="$(state_get "$name" nudges)"
    case "$prev_nudges" in ''|*[!0-9]*) prev_nudges=0 ;; esac
    prev_last="$(state_get "$name" last_nudge)"
    if [ "$prev_episode" != "$episode" ]; then
        prev_nudges=0
        prev_last=""
    fi

    if [ "$prev_nudges" -ge "$ESCALATE_AFTER" ]; then
        log "$name ($store): STALE — $detail; already nudged $prev_nudges time(s) and escalated, holding"
        state_put "$name" "$episode" "$prev_nudges" "$prev_last"
        continue
    fi

    if [ -n "$prev_last" ]; then
        last_epoch="$(printf '%s' "$prev_last" | jq -Rr 'try fromdateiso8601 catch empty' 2>/dev/null)"
        if [ -n "$last_epoch" ] && [ $(( now_epoch - last_epoch )) -lt "$renudge_s" ]; then
            log "$name ($store): STALE — $detail; nudged $(( now_epoch - last_epoch ))s ago, waiting out $RENUDGE_AFTER"
            state_put "$name" "$episode" "$prev_nudges" "$prev_last"
            continue
        fi
    fi

    msg="PATROL WAKE (patrol-wake order, not a human): your patrol wisp $wisp has not advanced in ${age_s}s. Run 'gc hook', then resume your patrol formula from the step you left off at — read next-iteration before you wait again. If a cycle is already mid-flight, finish it; do not start a second one."
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN $name ($store): STALE — $detail; would nudge (nudge #$(( prev_nudges + 1 )))"
        continue
    fi
    if gc session nudge "$name" "$msg" --delivery immediate >>"$LOG" 2>&1 </dev/null; then
        nudges=$(( prev_nudges + 1 ))
        nudged=$(( nudged + 1 ))
        log "$name ($store): STALE — $detail; NUDGED (#$nudges, delivery=immediate)"
        state_put "$name" "$episode" "$nudges" "$now_iso"
        if [ "$nudges" -ge "$ESCALATE_AFTER" ]; then
            gc mail send "$MAIL_TARGET" \
              -s "PATROL WAKE: $name has not resumed after $nudges nudges [HIGH]" \
              -m "The patrol-wake order has nudged $name $nudges times without its patrol wisp advancing.

Agent:   $name (template $template, store $store)
Wisp:    $wisp
Detail:  $detail
Stale:   >= $STALE_AFTER, re-nudge gap $RENUDGE_AFTER

A nudge is no longer working, so this order will stop nudging this episode and
will report again only once the wisp advances and stalls afresh. Nothing was
killed or restarted: that agent is a mode=always named session, exempt from the
idle-timeout and max-session-age trackers, so the controller will not recycle
it either (gcs-i31).

The remedy, if the pane confirms it is parked: 'gc session kill $name' — the
controller re-spawns a mode=always session promptly, and the poured wisp is
already assigned, so the fresh session resumes the patrol. That discards its
context, which is why this order will not do it for you.

Log: $LOG" >>"$LOG" 2>&1 </dev/null || log "WARN $name: escalation mail to $MAIL_TARGET failed"
            log "$name: escalated to $MAIL_TARGET after $nudges nudges"
        fi
    else
        log "ERROR $name ($store): nudge failed — $detail"
        errors=1
        state_put "$name" "$episode" "$prev_nudges" "$prev_last"
    fi
done <<ROWS
$rows
ROWS

log "sweep done: examined=$examined nudged=$nudged errors=$errors (stale_after=$STALE_AFTER renudge=$RENUDGE_AFTER escalate_after=$ESCALATE_AFTER templates=[$TEMPLATES])"
[ "$errors" -eq 0 ] || exit 1
exit 0
