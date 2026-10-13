#!/usr/bin/env bash
# Capture this fork's QUIC fixtures under LTTng and check them with the
# toolkit's `moq-trace verify`, as the mvfst and Quinn forks do.
#
#   moq_trace/test_trace.sh [bazel flags...]
#
# Needs the traced build environment, LTTng, and the moq-trace command on PATH,
# which the moq-trace checkout's development shell provides. The fixtures are
# duplicate and coalesced packets, GSO and sendmmsg batches with exact socket
# counts, and streams blocked by their own flow control, the connection's, and
# the send buffer.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
if ! command -v moq-trace >/dev/null 2>&1; then
  echo "moq-trace must be on PATH; run from the moq-trace development shell" >&2
  exit 1
fi
BAZEL_VERB=build TRACE=1 "$here/build.sh" "$here/.." "$@" \
  //quiche:quic_connection_test \
  //quiche:quic_stream_test \
  //quiche:quic_gso_batch_writer_test \
  //quiche:quic_sendmmsg_batch_writer_test

bin="$here/../bazel-bin/quiche"
mkdir -p "$here/artifacts"
output=$(mktemp -d "$here/artifacts/test-trace.XXXXXX")
echo "Trace evidence: $output"
moq-trace verify "$output" \
  --run "$bin/quic_connection_test --gtest_filter=*DuplicatePacket/*:*CoalescedPacket/*" \
  --run "$bin/quic_stream_test" \
  --run "$bin/quic_gso_batch_writer_test --gtest_filter=QuicGsoBatchWriterTest.WriteSuccess" \
  --run "$bin/quic_sendmmsg_batch_writer_test --gtest_filter=QuicSendmmsgBatchWriterTest.*" \
  --rx-outcome dropped \
  --socket success,1,2,1100=1 \
  --socket success,2,2,300=1 \
  --socket success,1,1,100=1 \
  --socket would_block,0,0,0=1 \
  --socket success,1,1,200=1 \
  --send-blocked stream_flow_control/stream \
  --send-blocked connection_flow_control/stream \
  --send-blocked send_buffer/stream
