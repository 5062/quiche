#!/usr/bin/env bash
# Run the MoQ test targets in this worktree, in either configuration.
#
#   moq_trace/test.sh             # with the trace hooks compiled in
#   TRACE=0 moq_trace/test.sh     # the ordinary QUICHE configuration
#
# Pass targets to run only those, and pass Bazel flags through, for example:
#   moq_trace/test.sh . --jobs=8 //quiche:moqt_parser_test
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
defaults="//quiche:moqt_parser_test //quiche:moqt_object_test //quiche:moqt_uni_stream_test //quiche:moqt_track_test //quiche:moqt_session_test //quiche:moqt_subscription_test //quiche:moqt_relay_test //quiche:moqt_relay_publisher_test //quiche:moqt_relay_track_publisher_test //quiche:moqt_integration_test"

MOQ_TRACE_DEFAULT_TARGETS="$defaults" BAZEL_VERB=test \
  exec "$here/build.sh" --test_output=errors "$@"
