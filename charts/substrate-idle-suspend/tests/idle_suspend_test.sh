#!/usr/bin/env bash
# Runs files/idle-suspend.sh with the config that the chart renders, against a stub of
# kubectl-ate and a stub of curl. The stubs exist because the script needs a control plane and
# Prometheus, which the checks do not have. They cover every branch: idle, each busy signal,
# each kind of query error, an actor that is not running and an actor that is missing.
# The kind harness covers the real client and the real query path.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="$here/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state/actors" "$work/config"

cat >"$work/bin/kubectl-ate" <<'STUB'
#!/usr/bin/env bash
set -eu
s="$STATE"
args=()
atespace=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preview) shift ;;
    --token-file | -o | --mode) [ "$1" != --mode ] || echo "mode $2" >>"$s/calls"; shift 2 ;;
    -a) atespace="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
case "$1 $2" in
  "get actor")
    f="$s/actors/$atespace.$3"
    if [ -e "$s/get-error" ]; then echo "rpc error: code = Unavailable desc = down" >&2; exit 1; fi
    [ -e "$f" ] || { echo "rpc error: code = NotFound desc = actor not found" >&2; exit 1; }
    read -r state template <"$f"
    if [ -e "$s/bad-json" ]; then echo "not json"; exit 0; fi
    jq -n --arg st "$state" --arg t "$template" --arg a "$atespace" '{actorTemplate:{name:$t,atespace:$a},status:{state:$st}}' ;;
  "suspend actor")
    echo "suspend actor $3 -a $atespace" >>"$s/calls"
    [ ! -e "$s/suspend-error" ] || { echo "rpc error: code = Internal desc = failed" >&2; exit 1; } ;;
  *) echo "stub: unexpected $*" >&2; exit 2 ;;
esac
STUB

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Answers a Prometheus query. The signal is named by the metric in the query. A file
# $STATE/value.<signal> holds the answer: a number, or ERR, EMPTY, MANY or NAN.
set -eu
s="$STATE"
query="" stdin=0
while [ $# -gt 0 ]; do
  case "$1" in
    --data-urlencode) query="${2#query=}"; shift 2 ;;
    -K) stdin=1; shift 2 ;;
    --max-time | --cacert) shift 2 ;;
    *) shift ;;
  esac
done
[ "$stdin" = 0 ] || cat >"$s/curl-stdin"
printf '%s\n' "$query" >>"$s/queries"
case "$query" in
  *envoy_server_live*'app="atenet-egress"'*) signal=health-egress ;;
  *envoy_server_live*) signal=health-envoy ;;
  *'app="atenet-router"'*) signal=health-router ;;
  *'app="ate-api-server"'*) signal=health-ateapi ;;
  *'app="atelet"'*) signal=health-atelet ;;
  *atenet_router_route_duration*) signal=routed ;;
  *lifecycle_operation*) signal=resumed ;;
  *envoy_http_downstream_rq_active*'app="atenet-egress"'*) signal=egress ;;
  *envoy_cluster_upstream_rq_active*) signal=inflight ;;
  *min_over_time*commands_in_flight*) signal=busy-cap ;;
  *commands_in_flight*) signal=busy ;;
  *ate_actor_stats_cpu_time*) signal=cpu ;;
  *) echo "stub: unknown query $query" >&2; exit 2 ;;
esac
echo "$signal" >>"$s/signals"
value="$(cat "$s/value.$signal")"
case "$value" in
  ERR) echo "curl: (22) The requested URL returned error: 503" >&2; exit 22 ;;
  EMPTY) echo '{"status":"success","data":{"resultType":"vector","result":[]}}' ;;
  MANY) echo '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1,"0"]},{"metric":{},"value":[1,"0"]}]}}' ;;
  BAD) echo '{"status":"error","errorType":"bad_data","error":"parse error"}' ;;
  *) printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1,"%s"]}]}}\n' "$value" ;;
esac
STUB
chmod +x "$work/bin/"*

# The config that the chart renders for the aws values file, one file for each ConfigMap key.
# render <dir> [helm args]: the busy signal is off unless the args turn it on.
render() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  helm template r "$chart" -f "$chart/ci/aws-values.yaml" -s templates/configmap.yaml "$@" |
  awk -v dir="$dir" '
    /^  [A-Za-z.-]+: \|$/ { if (out) close(out); name = $1; sub(/:$/, "", name); out = dir "/" name; printf "" > out; next }
    out && /^    / { sub(/^    /, ""); print > out; next }
    out && /^[^ ]/ { close(out); out = "" }
  '
}
render "$work/config"
render "$work/config-busy" --set busy.enabled=true
for f in actors config.env query.health.envoy query.health.egress query.health.router query.health.ateapi query.health.atelet query.routed query.resumed query.inflight query.egress query.cpu; do
  test -s "$work/config/$f" || { echo "FAIL: the chart did not render $f"; exit 1; }
done

state="$work/state"
reset() {
  rm -f "$state"/bad-json "$state"/calls "$state"/queries "$state"/signals "$state"/value.* "$state"/get-error "$state"/suspend-error "$state"/curl-stdin "$state"/actors/*
  : >"$state/calls"
  : >"$state/queries"
  : >"$state/signals"
  local s
  for s in routed resumed inflight egress busy busy-cap cpu; do echo 0 >"$state/value.$s"; done
  for s in health-envoy health-egress health-router health-ateapi health-atelet; do echo 1 >"$state/value.$s"; done
  echo 0.001 >"$state/value.cpu"
  # The aws values file lists reviews/pr-review.
  echo "ACTOR_STATE_RUNNING pr-review-0123456789" >"$state/actors/reviews.pr-review"
}

run() {
  PATH="$work/bin:$PATH" STATE="$state" CONFIG_DIR="${CONFIG_DIR_OVERRIDE:-$work/config}" TOKEN_FILE="$work/token" \
    PROMETHEUS_TOKEN_FILE="${PROMETHEUS_TOKEN_FILE:-}" \
    bash "$chart/files/idle-suspend.sh" >"$work/out" 2>&1
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- output" >&2
  cat "$work/out" >&2
  echo "--- calls" >&2
  cat "$state/calls" >&2
  exit 1
}
suspended() { grep -q '^suspend actor' "$state/calls"; }

expect_suspend() {
  run || fail "$1 (the script failed)"
  suspended || fail "$1 (nothing was suspended)"
  echo "ok: $1"
}
expect_no_suspend() {
  run || fail "$1 (the script failed)"
  ! suspended || fail "$1 (the actor was suspended)"
  echo "ok: $1"
}
expect_failure_no_suspend() {
  if run; then fail "$1 (the script passed)"; fi
  ! suspended || fail "$1 (the actor was suspended)"
  echo "ok: $1"
}

echo "pr-review" >"$work/token"

reset
expect_suspend "an idle running actor is suspended"
grep -qx 'mode async' "$state/calls" || fail "the suspend did not pass the mode"
grep -q 'suspend actor pr-review -a reviews' "$state/calls" || fail "the suspend named the wrong actor"
grep -q 'ate_template_name="pr-review-0123456789"' "$state/queries" || fail "the queries did not name the template of the actor"
grep -q 'offset 30m' "$state/queries" || fail "the queries did not use the idle time"
grep -q '@' "$state/queries" && fail "a placeholder is left in a query"

reset
echo 0.05 >"$state/value.cpu"
expect_suspend "a CPU use equal to the threshold counts as idle"

for signal in routed resumed inflight egress; do
  reset
  echo 1 >"$state/value.$signal"
  expect_no_suspend "the $signal signal alone keeps the actor"
done
reset
echo 0.06 >"$state/value.cpu"
expect_no_suspend "a CPU use above the threshold keeps the actor"
grep -q 'is busy ( cpu )' "$work/out" || fail "the output did not name the busy signal"

reset
echo 1 >"$state/value.routed"; echo 1 >"$state/value.cpu"
expect_no_suspend "several busy signals keep the actor"

reset
echo 1 >"$state/value.resumed"
echo ERR >"$state/value.cpu"
expect_no_suspend "a busy signal ends the check before a later query that would fail"
grep -qx cpu "$state/signals" && fail "the cpu query ran after a busy signal"

for signal in health-envoy health-egress health-router health-ateapi health-atelet routed resumed inflight egress cpu; do
  for mode in ERR EMPTY MANY NAN BAD; do
    reset
    echo "$mode" >"$state/value.$signal"
    expect_failure_no_suspend "a $mode answer to the $signal query fails the run"
  done
done

for source in envoy egress router ateapi atelet; do
  reset
  echo 0 >"$state/value.health-$source"
  expect_failure_no_suspend "a missing $source series (health returns 0) fails the run"
  grep -q "the $source metrics are missing" "$work/out" || fail "the output did not name the missing $source source"
  test ! -s "$state/signals" || ! grep -qx 'routed\|cpu\|resumed\|inflight\|egress' "$state/signals" || fail "a signal query ran although the $source check failed"
done

# The busy signal. It is off by default, so the default config never sends its query.
reset
grep -qx 'BUSY_ENABLED=false' "$work/config/config.env" || fail "busy is not off by default"
test ! -e "$work/config/query.busy" || fail "the chart rendered the busy query with busy off"
echo 1 >"$state/value.busy"
expect_suspend "with busy off, the busy gauge is not read and the actor is suspended"
grep -q commands_in_flight "$state/queries" && fail "the busy query was sent with busy off"

CONFIG_DIR_OVERRIDE="$work/config-busy"
reset
expect_suspend "with busy on and the gauge at 0, an idle actor is suspended"
grep -q 'sum(pr_agent_commands_in_flight{ate_actor="reviews/pr-review"})' "$state/queries" || fail "the busy query did not name the metric and the actor"
grep -q 'max_over_time.*\[30m:15s\]' "$state/queries" || fail "the busy query did not use the idle time"
grep -q 'busy=0' "$work/out" || fail "the log line did not list busy"

reset
echo 1 >"$state/value.busy"
expect_no_suspend "the busy signal alone keeps the actor"
grep -q 'is busy ( busy )' "$work/out" || fail "the output did not name the busy signal"
grep -q 'busy=1' "$work/out" || fail "the log line did not list busy=1"

reset
echo 1 >"$state/value.busy"
echo 1 >"$state/value.busy-cap"
expect_suspend "a gauge above 0 for the whole cap is ignored as stale"
grep -q 'whole cap of 30 minutes' "$work/out" || fail "the output did not say that the cap ignored the gauge"
grep -q 'min_over_time.*\[30m:15s\]' "$state/queries" || fail "the cap query did not use the cap"

reset
echo 1 >"$state/value.busy"
echo 1 >"$state/value.busy-cap"
echo 1 >"$state/value.routed"
expect_no_suspend "a stale gauge does not hide another busy signal"

reset
echo ERR >"$state/value.busy-cap"
expect_suspend "the cap is not queried when the gauge is 0"

for mode in ERR EMPTY MANY NAN BAD; do
  reset
  echo "$mode" >"$state/value.busy"
  expect_failure_no_suspend "a $mode answer to the busy query fails the run"
  reset
  echo 1 >"$state/value.busy"
  echo "$mode" >"$state/value.busy-cap"
  expect_failure_no_suspend "a $mode answer to the busy cap query fails the run"
done
unset CONFIG_DIR_OVERRIDE

reset
echo "ACTOR_STATE_SUSPENDED pr-review-0123456789" >"$state/actors/reviews.pr-review"
expect_no_suspend "a suspended actor is left alone"
test ! -s "$state/queries" || fail "the script queried Prometheus for an actor that is not running"
for other in ACTOR_STATE_RESUMING ACTOR_STATE_SUSPENDING ACTOR_STATE_CRASHED ACTOR_STATE_REVERTING; do
  echo "$other pr-review-0123456789" >"$state/actors/reviews.pr-review"
  expect_no_suspend "an actor in $other is left alone"
done

reset
rm "$state/actors/reviews.pr-review"
expect_failure_no_suspend "a missing actor fails the run"
grep -q 'does not exist' "$work/out" || fail "the output did not say that the actor is missing"

reset
touch "$state/get-error"
expect_failure_no_suspend "an error from the control plane fails the run"

reset
touch "$state/suspend-error"
if run; then fail "a failed suspend passed"; fi
echo "ok: a failed suspend fails the run"

reset
echo "ACTOR_STATE_RUNNING bad\"name" >"$state/actors/reviews.pr-review"
expect_failure_no_suspend "a template name that is not a plain name fails the run"
test ! -s "$state/queries" || fail "a bad template name reached a query"

reset
PROMETHEUS_TOKEN_FILE="$work/prom-token"
printf 's3cret\n' >"$PROMETHEUS_TOKEN_FILE"
expect_suspend "an idle actor is suspended with a bearer token"
grep -qx 'header = "Authorization: Bearer s3cret"' "$state/curl-stdin" || fail "the token did not reach curl on stdin"
PROMETHEUS_TOKEN_FILE=""

# A second actor in the list: one failing actor must not stop the other, and the run still fails.
reset
printf 'reviews/pr-review\nreviews/second\n' >"$work/config/actors"
echo "ACTOR_STATE_RUNNING second-0123456789" >"$state/actors/reviews.second"
rm "$state/actors/reviews.pr-review"
if run; then fail "a run with a missing actor passed"; fi
grep -q 'suspend actor second -a reviews' "$state/calls" || fail "the missing actor stopped the check of the other actor"
! grep -q 'suspend actor pr-review' "$state/calls" || fail "a missing actor was suspended"
grep -q 'FAILED: reviews/pr-review' "$work/out" || fail "the output did not name the failed actor"
echo "ok: a failing actor does not stop the next actor, and the run fails"

reset
: >"$work/config/actors"
expect_failure_no_suspend "an empty actor list fails the run"

reset
touch "$state/bad-json"
expect_failure_no_suspend "a state that is not valid JSON fails the run"

reset
cat >"$work/bin/awk" <<'AWK'
#!/usr/bin/env bash
exit 2
AWK
chmod +x "$work/bin/awk"
expect_failure_no_suspend "an awk failure fails the run and does not read as idle"
rm "$work/bin/awk"
