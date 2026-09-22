#!/usr/bin/env bash
# Capture a live MoQ draft-16 run through the traced QUICHE relay.
#
#   moq_trace/capture.sh <output-dir> <relay-binary> [loopback|upstream]
#
# loopback: the moq-bench client publishes into the relay and subscribes to the
#   same track through it.
# upstream: a moq-bench-server publishes and the relay subscribes upstream with
#   --default_upstream.
#
# Environment: PORT (default 19667), DURATION (default 6s),
# MOQ_TRACE_BENCH_CLIENT, MOQ_TRACE_BENCH_SERVER, MOQ_TRACE_CERT, and
# MOQ_TRACE_KEY. A self-signed certificate for 127.0.0.1 and localhost is
# generated into the output directory when neither is given; both peers run
# with verification disabled.
set -euo pipefail

out=${1:?usage: capture.sh <output-dir> <relay-binary> [loopback|upstream]}
relay=${2:?usage: capture.sh <output-dir> <relay-binary> [loopback|upstream]}
topology=${3:-loopback}
if [ "$topology" != loopback ] && [ "$topology" != upstream ]; then
  echo "topology must be loopback or upstream" >&2
  exit 1
fi

# The active development environment supplies the tracing, analysis, and
# benchmark tools.
for tool in lttng babeltrace2 moq-trace openssl ss; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool must be on PATH" >&2
    exit 1
  fi
done
bench_client=${MOQ_TRACE_BENCH_CLIENT:-$(command -v moq-bench || true)}
bench_server=${MOQ_TRACE_BENCH_SERVER:-$(command -v moq-bench-server || true)}
if [ -z "$bench_client" ] || ! command -v "$bench_client" >/dev/null 2>&1; then
  echo "moq-bench must be on PATH or set through MOQ_TRACE_BENCH_CLIENT" >&2
  exit 1
fi
if [ "$topology" = upstream ] &&
   { [ -z "$bench_server" ] || ! command -v "$bench_server" >/dev/null 2>&1; }; then
  echo "moq-bench-server must be on PATH or set through MOQ_TRACE_BENCH_SERVER" >&2
  exit 1
fi
duration=${DURATION:-6s}
session=moqtrace-$$
port=${PORT:-19667}
upstream_port=$((port + 1))

mkdir -p "$(dirname "$out")"
if ! mkdir "$out"; then
  echo "capture output already exists: $out" >&2
  exit 1
fi

relay_pid=""
server_pid=""
session_started=0
cleanup() {
  status=$?
  trap - EXIT INT TERM
  set +e
  [ -z "$relay_pid" ] || kill "$relay_pid" 2>/dev/null
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null
  wait 2>/dev/null
  if [ "$session_started" = 1 ]; then
    lttng stop >/dev/null 2>&1
    lttng destroy "$session" >/dev/null 2>&1
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# The capture has to be reproducible from this checkout alone, so mint the
# throwaway certificate here instead of depending on a leftover temporary one.
cert=${MOQ_TRACE_CERT:-$out/relay.crt}
key=${MOQ_TRACE_KEY:-$out/relay.key}
if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
  command -v openssl >/dev/null 2>&1 || { echo "openssl is needed to mint $cert" >&2; exit 1; }
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$key" -out "$cert" -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
fi

# A leftover relay from an earlier run silently wins the port and would then be
# the process under test, so refuse to start when the port is already taken.
if ss -lun "sport = :$port" | tail -n +2 | grep -q .; then
  echo "port $port is already in use" >&2
  exit 1
fi

lttng create "$session" --output "$out/session"
lttng enable-channel -u channel0 --subbuf-size=8M >/dev/null
lttng enable-event -u -c channel0 -a
# vpid is what --pid selects on, and vtid distinguishes the relay's threads.
lttng add-context -u -c channel0 -t vpid -t vtid -t procname
lttng start
session_started=1

if [ "$topology" = upstream ]; then
  "$bench_server" --server-bind "[::]:$upstream_port" --tls-cert "$cert" --tls-key "$key" \
    --server-version moq-transport-16 --log-level debug > "$out/server.log" 2>&1 &
  server_pid=$!
  sleep 0.5
  "$relay" --bind_address 127.0.0.1 --port "$port" --default_upstream "https://127.0.0.1:$upstream_port" \
    --certificate_file "$cert" --key_file "$key" --disable_certificate_verification \
    --v=1 > "$out/relay.log" 2>&1 &
else
  "$relay" --bind_address 127.0.0.1 --port "$port" \
    --certificate_file "$cert" --key_file "$key" --v=1 > "$out/relay.log" 2>&1 &
fi
relay_pid=$!
captured_relay_pid=$relay_pid
echo "relay pid $relay_pid (pass it to moq-trace analyze --pid)"
for _ in $(seq 1 50); do
  ss -lun "sport = :$port" | tail -n +2 | grep -q . && break
  kill -0 "$relay_pid" 2>/dev/null || { echo "relay exited during startup" >&2; cat "$out/relay.log" >&2; exit 1; }
  sleep 0.1
done
ss -lun "sport = :$port" | tail -n +2 | grep -q . || { echo "relay never listened" >&2; exit 1; }

"$bench_client" --client-connect "https://127.0.0.1:$port" --client-tls-disable-verify \
  --broadcasts 1 --subscribe 1 --fps 20 --frame-size 4096 --duration "$duration" \
  --report 2s --log-level debug > "$out/client.log" 2>&1
sleep 0.3

kill "$relay_pid" $server_pid 2>/dev/null || true
wait 2>/dev/null || true
relay_pid=""
server_pid=""
lttng stop >/dev/null
lttng destroy "$session" >/dev/null
session_started=0

babeltrace2 "$out/session" > "$out/events.txt"
grep -o "moq_trace:[a-z_]*\|quic_trace:[a-z_]*" "$out/events.txt" | sort | uniq -c
echo "--- benchmark stats ---"
grep -ao 'stats .*' "$out/client.log" | tail -3
echo "--- relay process ids in the capture ---"
grep -ao 'vpid = [0-9]*' "$out/events.txt" | sort -u
moq-trace analyze "$out/session" --output "$out/trace.duckdb" \
  --object-size 4096 --subscribers 1 --pid "$captured_relay_pid"
