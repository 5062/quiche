#!/usr/bin/env bash
# Build a target in this QUICHE worktree, optionally with the MoQ trace hooks.
#
#   moq_trace/build.sh [worktree] [target] [bazel flags...]
#
# The traced configuration needs the moq-trace2 C++ headers and the two LTTng
# provider archives. They live outside the Bazel execution root, so Bazel cannot
# model them as a hermetic dependency and they are passed through --cxxopt,
# --linkopt, and CPLUS_INCLUDE_PATH instead.
#
# Toolchain locations default to the Nix development shell used for this fork.
# Override them with the MOQ_TRACE_* environment variables.
set -euo pipefail

worktree=${1:-$(cd "$(dirname "$0")/.." && pwd)}
target=${2:-//quiche:moqt_relay}
shift 2 2>/dev/null || shift 1

CLANG=${MOQ_TRACE_CLANG:-/nix/store/874j5xydsj6nr6i1zdrjvhln5gmxvvrr-clang-wrapper-21.1.8}
BAZELISK=${MOQ_TRACE_BAZELISK:-/nix/store/bnxk2g7srfbmm0ghhlzimkzshpwls211-bazelisk-1.28.1/bin/bazelisk}
ICU_DEV=${MOQ_TRACE_ICU_DEV:-/nix/store/4dn9hz9kl3fvcr4y09n6vdr302bldwcj-icu4c-76.1-dev}
ICU_LIB=${MOQ_TRACE_ICU_LIB:-/nix/store/clpq5c7bysml4vqpa1x60a5yk3nzkfj4-icu4c-76.1}
TRACE_PREFIX=${MOQ_TRACE_PREFIX:-/home/siyuan/moq-trace2/target/install}

common=(
  --features=-layering_check
  --repo_env=CC --repo_env=CXX --repo_env=CPLUS_INCLUDE_PATH
  --action_env=CC --action_env=CXX --action_env=CPLUS_INCLUDE_PATH
  --linkopt=-L"$ICU_LIB"/lib
  --linkopt=-licui18n --linkopt=-licuuc --linkopt=-licudata
)

trace=(
  --cxxopt=-DQUICHE_MOQ_TRACE
  --linkopt="$TRACE_PREFIX"/lib/libmoq_trace_provider.a
  --linkopt="$TRACE_PREFIX"/lib/libquic_trace_provider.a
  --linkopt=-L"$(pkg-config --variable=libdir lttng-ust)"
  --linkopt=-llttng-ust
  --linkopt=-llttng-ust-common
  --linkopt=-ldl
  --linkopt=-Wl,-u,__start_lttng_ust_tracepoints_ptrs
)

# TRACE=0 builds the same sources with the hooks compiled out, which is the
# configuration an ordinary QUICHE checkout sees.
if [ "${TRACE:-1}" = 0 ]; then
  trace=()
fi

cd "$worktree"
export CC="$CLANG"/bin/clang
export CXX="$CLANG"/bin/clang++
export CPLUS_INCLUDE_PATH="$ICU_DEV"/include:"$TRACE_PREFIX"/include
exec "$BAZELISK" --output_base="$worktree"/bazel-outbase build -c opt \
  "${common[@]}" "$@" "${trace[@]}" "$target"
