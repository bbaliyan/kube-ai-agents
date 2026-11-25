#!/usr/bin/env bash
# Suspends running actors that show no activity for the idle time.
#
# Why a script: Agent Substrate v1.0.1 has no idle policy. Suspend is an API call that only
# `kubectl ate` makes, and the decision joins the actor state of the control plane with the
# signals in Prometheus. No declarative resource does either. Delete this chart when upstream
# ships its own policy (agent-substrate/substrate issues 424 and 483).
#
# Fail-safe: the script suspends an actor only when every step succeeded and every signal says
# idle. An error in any step, such as a failed query, a query with no sample or an unknown value,
# ends the run with a non-zero exit code and suspends nothing for that actor.
#
# Input: $CONFIG_DIR/actors holds one line for each actor, atespace/name. config.env holds the
# settings. With BUSY_ENABLED=true the optional busy signal runs, and query.busy.cap holds the stale-value cap. query.<signal> holds the PromQL of each signal, and query.health.<source> the query
# that shows the source of a signal exists. Each query returns one sample.
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/config}"
NS="${SUBSTRATE_NAMESPACE:-ate-system}"
TOKEN_FILE="${TOKEN_FILE:-/var/run/ate/token}"
WORK="$(mktemp -d)"
export ATE_NAMESPACE="$NS"

IDLE_MINUTES="" IDLE_CPU_CORES="" SUSPEND_MODE="" PROMETHEUS_URL="" QUERY_TIMEOUT="" BUSY_ENABLED="" BUSY_MAX_MINUTES="" ACTOR=""
VALUE=""

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
ate() { kubectl-ate --preview --token-file "$TOKEN_FILE" "$@"; }

# Reads the settings without running the file as shell code.
load_config() {
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      IDLE_MINUTES | IDLE_CPU_CORES | SUSPEND_MODE | PROMETHEUS_URL | QUERY_TIMEOUT | BUSY_ENABLED | BUSY_MAX_MINUTES) printf -v "$key" '%s' "$value" ;;
    esac
  done <"$CONFIG_DIR/config.env"
  local name
  for name in IDLE_MINUTES IDLE_CPU_CORES SUSPEND_MODE PROMETHEUS_URL QUERY_TIMEOUT BUSY_ENABLED BUSY_MAX_MINUTES; do
    [ -n "${!name}" ] || { err "$name is not set in config.env"; return 1; }
  done
}

# Runs one query and puts the single sample value in VALUE. Any other result is an error.
# $1 is the name of the signal, $2 the atespace and $3 the template of the actor.
query() {
  local signal="$1" atespace="$2" template="$3" expr body count
  expr="$(cat "$CONFIG_DIR/query.$signal")" || return 1
  expr="${expr//@ATESPACE@/$atespace}"
  expr="${expr//@TEMPLATE@/$template}"
  expr="${expr//@WINDOW@/${IDLE_MINUTES}m}"
  expr="${expr//@CAP@/${BUSY_MAX_MINUTES}m}"
  expr="${expr//@ACTOR@/$ACTOR}"
  local args=(-sS --fail-with-body --max-time "$QUERY_TIMEOUT" --get --data-urlencode "query=$expr")
  [ -z "${PROMETHEUS_CA_FILE:-}" ] || args+=(--cacert "$PROMETHEUS_CA_FILE")
  if [ -n "${PROMETHEUS_TOKEN_FILE:-}" ]; then
    # The token goes in over stdin, so it is not on the command line.
    body="$(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$PROMETHEUS_TOKEN_FILE")" |
      curl "${args[@]}" -K - "$PROMETHEUS_URL/api/v1/query" 2>"$WORK/curl-stderr")" || { err "the $signal query failed: $(cat "$WORK/curl-stderr") $body"; return 1; }
  else
    body="$(curl "${args[@]}" "$PROMETHEUS_URL/api/v1/query" 2>"$WORK/curl-stderr")" || { err "the $signal query failed: $(cat "$WORK/curl-stderr") $body"; return 1; }
  fi
  count="$(jq -r 'if .status == "success" and .data.resultType == "vector" then (.data.result | length) else -1 end' <<<"$body" 2>/dev/null)" || count=-1
  if [ "$count" != 1 ]; then
    err "the $signal query returned $count samples, expected 1: $expr"
    return 1
  fi
  VALUE="$(jq -r '.data.result[0].value[1]' <<<"$body")"
  if ! [[ "$VALUE" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
    err "the $signal query returned '$VALUE', which is not a number"
    return 1
  fi
}

# True when $1 is greater than $2. An awk error (exit code 2) ends the script, so it never reads as idle.
above() {
  local rc=0
  awk -v v="$1" -v t="$2" 'BEGIN { exit !(v > t) }' || rc=$?
  if [ "$rc" -gt 1 ]; then
    err "awk failed to compare $1 with $2"
    exit 2
  fi
  [ "$rc" -eq 0 ]
}

check_actor() {
  local atespace="$1" name="$2" json state template template_atespace busy="" signal threshold source
  ACTOR="$atespace/$name"
  if ! json="$(ate get actor "$name" -a "$atespace" -o json 2>"$WORK/stderr")"; then
    case "$(cat "$WORK/stderr")" in
      *NotFound*) err "actor $atespace/$name does not exist" ;;
      *) cat "$WORK/stderr" >&2 ;;
    esac
    return 1
  fi
  state="$(jq -r '.status.state // ""' <<<"$json")" || { err "the state of actor $atespace/$name is not valid JSON"; return 1; }
  if [ "$state" != ACTOR_STATE_RUNNING ]; then
    log "Actor $atespace/$name is ${state:-without a state}. Nothing to do."
    return 0
  fi
  template="$(jq -r '.actorTemplate.name // ""' <<<"$json")" || return 1
  template_atespace="$(jq -r '.actorTemplate.atespace // ""' <<<"$json")" || return 1
  template_atespace="${template_atespace:-$atespace}"
  # The names go into PromQL, so refuse anything but a plain name.
  [[ "$template" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { err "actor $atespace/$name has the template name '$template'"; return 1; }
  [[ "$template_atespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { err "actor $atespace/$name has the template atespace '$template_atespace'"; return 1; }

  # Every source of a signal must exist, or a missing series would read as silence.
  for source in envoy egress router ateapi atelet; do
    query "health.$source" "$template_atespace" "$template" || return 1
    above "$VALUE" 0 || { err "the $source metrics are missing or not scraped: the health.$source query returned $VALUE"; return 1; }
  done

  local summary=""
  for signal in routed resumed inflight egress busy cpu; do
    [ "$signal" != busy ] || [ "$BUSY_ENABLED" = true ] || continue
    query "$signal" "$template_atespace" "$template" || return 1
    if [ "$signal" = busy ] && above "$VALUE" 0; then
      # A gauge above 0 for the whole cap is a stale value (a crash or a suspend in a command), not work.
      local busy_value="$VALUE"
      query busy.cap "$template_atespace" "$template" || return 1
      if above "$VALUE" 0; then
        log "Actor $ACTOR: the busy gauge stayed above 0 for the whole cap of $BUSY_MAX_MINUTES minutes. Ignore it as stale."
        VALUE=0
      else
        VALUE="$busy_value"
      fi
    fi
    threshold=0
    [ "$signal" != cpu ] || threshold="$IDLE_CPU_CORES"
    summary="$summary $signal=$VALUE"
    # One busy signal decides: the actor stays. The later queries are not run, so an actor that
    # was just resumed (its CPU series may not exist yet) does not fail the run.
    if above "$VALUE" "$threshold"; then
      busy=" $signal"
      break
    fi
  done
  if [ -n "$busy" ]; then
    log "Actor $atespace/$name is busy ($busy ). Signals:$summary"
    return 0
  fi
  log "Actor $atespace/$name is idle. Signals:$summary. Suspend it."
  ate suspend actor "$name" -a "$atespace" --mode "$SUSPEND_MODE"
}

load_config
failed=()
count=0
while read -r -u 3 line; do
  [ -n "$line" ] || continue
  count=$((count + 1))
  if ! check_actor "${line%%/*}" "${line#*/}"; then
    failed+=("$line")
  fi
done 3<"$CONFIG_DIR/actors"

if [ "$count" -eq 0 ]; then
  err "no actor is configured"
  exit 1
fi
if [ "${#failed[@]}" -gt 0 ]; then
  log "FAILED: ${failed[*]}. Nothing was suspended for these actors."
  exit 1
fi
log "Done."
