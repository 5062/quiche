#!/usr/bin/env bash
# Analyze a capture from this fork with the moq-trace2 analyzer.
#
#   moq_trace/analyze.sh <ctf-session-dir> --output out.duckdb \
#     --object-size 4096 --subscribers 1 --pid <relay-vpid>
#
# capture.sh prints the relay pid and the exact command for the capture it just
# wrote. All arguments are passed straight to `moq-trace analyze`.
set -euo pipefail

# The analyzer, its Python dependencies, and Babeltrace 2 come from the
# moq-trace2 development shell, so re-exec inside it when it is not installed.
MOQ_TRACE2_SRC=${MOQ_TRACE2_SRC:-$(cd "$(dirname "$0")/../.." && pwd)/moq-trace2}
if [ "${MOQ_TRACE_IN_DEVSHELL:-0}" != 1 ] && ! command -v moq-trace >/dev/null 2>&1; then
  export MOQ_TRACE_IN_DEVSHELL=1
  exec nix --extra-experimental-features 'nix-command flakes' develop \
    "$MOQ_TRACE2_SRC" --command bash "${BASH_SOURCE[0]}" "$@"
fi

exec moq-trace analyze "$@"
