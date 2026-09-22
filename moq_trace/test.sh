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

default_targets=(
  //quiche:moqt_parser_test
  //quiche:moqt_object_test
  //quiche:moqt_uni_stream_test
  //quiche:moqt_track_test
  //quiche:moqt_session_test
  //quiche:moqt_subscription_test
  //quiche:moqt_relay_test
  //quiche:moqt_relay_publisher_test
  //quiche:moqt_relay_track_publisher_test
  //quiche:moqt_integration_test
)

# Same argument rule as build.sh, so an option can never be mistaken for a
# target: options are flags, the first argument that names a directory is the
# worktree, and everything else is a target.
worktree=""
flags=()
targets=()
for arg in "$@"; do
  case $arg in
    -*) flags+=("$arg") ;;
    *) if [ -z "$worktree" ] && [ -d "$arg" ]; then worktree=$arg; else targets+=("$arg"); fi ;;
  esac
done
if [ ${#targets[@]} -eq 0 ]; then
  targets=("${default_targets[@]}")
fi

args=(--test_output=errors "${flags[@]}" "${targets[@]}")
if [ -n "$worktree" ]; then
  args=("$worktree" "${args[@]}")
fi

BAZEL_VERB=test exec "$here/build.sh" "${args[@]}"
