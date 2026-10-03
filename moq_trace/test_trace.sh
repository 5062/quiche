#!/usr/bin/env bash
# Capture focused real packet and mocked syscall fixtures, then verify emissions.
# Requires the traced build environment, LTTng, and Python's Babeltrace 2 bindings.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
BAZEL_VERB=build TRACE=1 "$here/build.sh" "$here/.." "$@" \
  //quiche:quic_connection_test \
  //quiche:quic_gso_batch_writer_test \
  //quiche:quic_sendmmsg_batch_writer_test

mkdir -p "$here/artifacts"
output=$(mktemp -d "$here/artifacts/test-trace.XXXXXX")
echo "Trace evidence: $output"
session="quiche-test-trace-$$"
trap 'lttng destroy "$session" >/dev/null 2>&1 || true' EXIT
lttng create "$session" --output "$output/ctf"
lttng enable-event -u 'quic_trace:*'
lttng add-context -u --type vpid
lttng start
export LTTNG_UST_REGISTER_TIMEOUT=-1
"$here/../bazel-bin/quiche/quic_connection_test" \
  --gtest_filter='*DuplicatePacket/*:*CoalescedPacket/*' >"$output/packets.log" 2>&1
"$here/../bazel-bin/quiche/quic_gso_batch_writer_test" \
  --gtest_filter='QuicGsoBatchWriterTest.WriteSuccess' >"$output/gso.log" 2>&1
"$here/../bazel-bin/quiche/quic_sendmmsg_batch_writer_test" \
  --gtest_filter='QuicSendmmsgBatchWriterTest.*' >"$output/sendmmsg.log" 2>&1
lttng stop
lttng destroy "$session"
trap - EXIT
python "$here/check_test_trace.py" "$output/ctf"
echo "Trace evidence: $output"
