#!/usr/bin/env bash
# Build targets in this QUICHE worktree, optionally with the MoQ trace hooks.
#
#   moq_trace/build.sh [worktree] [bazel target...]
#
# TRACE=0 compiles the hooks out. BAZEL_VERB=test runs bazel test instead of
# bazel build, which is what moq_trace/test.sh uses.
#
# MOQ_TRACE_OUTBASE redirects the build to a separate Bazel output base, which
# is how the traced and untraced configurations keep their compiled artifacts
# instead of invalidating each other. It leaves the workspace bazel-* symlinks
# pointing at the default output base so `./bazel-bin/quiche/moqt_relay` stays
# the traced binary.
#
# The traced configuration needs the moq-trace2 C++ headers and the two LTTng
# provider archives. They live outside the Bazel execution root, so Bazel cannot
# model them as a hermetic dependency and they are passed through --cxxopt,
# --linkopt, and CPLUS_INCLUDE_PATH instead.
#
# Toolchain locations come from the active environment. Override individual
# paths with the MOQ_TRACE_* environment variables when needed.
set -euo pipefail

# Options are collected wherever they appear. The first remaining argument is
# the worktree when it names a directory, so "build.sh . //quiche:moqt_relay"
# and "build.sh --jobs=8" both do what they look like; the rest are targets.
here=$(cd "$(dirname "$0")/.." && pwd)
worktree=""
flags=()
targets=()
for arg in "$@"; do
  case $arg in
    -*) flags+=("$arg") ;;
    *) if [ -z "$worktree" ] && [ -d "$arg" ]; then worktree=$arg; else targets+=("$arg"); fi ;;
  esac
done
worktree=${worktree:-$here}
if [ ${#targets[@]} -eq 0 ]; then
  read -r -a targets <<< "${MOQ_TRACE_DEFAULT_TARGETS:-//quiche:moqt_relay}"
fi

CLANG=${MOQ_TRACE_CLANG:-$(command -v clang || true)}
CLANGXX=${MOQ_TRACE_CLANGXX:-$(command -v clang++ || true)}
BAZELISK=${MOQ_TRACE_BAZELISK:-$(command -v bazelisk || command -v bazel || true)}
if [ -z "$CLANG" ] || [ -z "$CLANGXX" ] || [ -z "$BAZELISK" ]; then
  echo "clang, clang++, and bazelisk (or bazel) must be on PATH" >&2
  exit 1
fi
if ! command -v pkg-config >/dev/null 2>&1; then
  echo "pkg-config must be on PATH" >&2
  exit 1
fi
if { [ -z "${MOQ_TRACE_ICU_INCLUDE:-}" ] ||
     [ -z "${MOQ_TRACE_ICU_LIBDIR:-}" ]; } && ! pkg-config --exists icu-uc; then
  echo "ICU must be available through pkg-config" >&2
  exit 1
fi
ICU_INCLUDE=${MOQ_TRACE_ICU_INCLUDE:-$(pkg-config --variable=includedir icu-uc)}
ICU_LIBDIR=${MOQ_TRACE_ICU_LIBDIR:-$(pkg-config --variable=libdir icu-uc)}

common=(
  --features=-layering_check
  --repo_env=CC --repo_env=CXX --repo_env=CPLUS_INCLUDE_PATH
  --action_env=CC --action_env=CXX --action_env=CPLUS_INCLUDE_PATH
  --linkopt=-L"$ICU_LIBDIR"
  --linkopt=-licui18n --linkopt=-licuuc --linkopt=-licudata
)

# TRACE=0 builds the same sources with the hooks compiled out, which is the
# configuration an ordinary QUICHE checkout sees.
trace=()
trace_prefix=""
if [ "${TRACE:-1}" = 0 ]; then
  :
else
  trace_prefix=${MOQ_TRACE_PREFIX:-}
  if [ -z "$trace_prefix" ]; then
    echo "MOQ_TRACE_PREFIX must name an installed moq-trace prefix" >&2
    exit 1
  fi
  if [ ! -f "$trace_prefix/lib/libmoq_trace_provider.a" ] ||
     [ ! -f "$trace_prefix/lib/libquic_trace_provider.a" ] ||
     [ ! -f "$trace_prefix/include/moq_trace/trace.hpp" ] ||
     [ ! -f "$trace_prefix/include/quic_trace/trace.hpp" ]; then
    echo "trace headers or providers are missing from $trace_prefix" >&2
    exit 1
  fi
  if ! pkg-config --exists lttng-ust; then
    echo "LTTng-UST must be available through pkg-config" >&2
    exit 1
  fi
  trace=(
    --cxxopt=-DQUICHE_MOQ_TRACE
    --linkopt="$trace_prefix"/lib/libmoq_trace_provider.a
    --linkopt="$trace_prefix"/lib/libquic_trace_provider.a
    --linkopt=-L"$(pkg-config --variable=libdir lttng-ust)"
    --linkopt=-llttng-ust
    --linkopt=-llttng-ust-common
    --linkopt=-ldl
    --linkopt=-Wl,-u,__start_lttng_ust_tracepoints_ptrs
  )
  echo "trace prefix: $trace_prefix" >&2
fi

cd "$worktree"
export CC="$CLANG"
export CXX="$CLANGXX"
export CPLUS_INCLUDE_PATH="$ICU_INCLUDE${trace_prefix:+:$trace_prefix/include}${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"

# An alternate output base would otherwise rewrite the workspace bazel-* symlinks
# and silently redirect `./bazel-bin/quiche/moqt_relay` at the other build.
# --output_base is a startup option, so it goes before the verb, while
# --experimental_convenience_symlinks is a build option and goes after it.
startup=(--output_base="$worktree"/bazel-outbase)
build_opts=()
if [ -n "${MOQ_TRACE_OUTBASE:-}" ]; then
  startup=(--output_base="$MOQ_TRACE_OUTBASE")
  build_opts=(--experimental_convenience_symlinks=ignore)
fi

exec "$BAZELISK" "${startup[@]}" "${BAZEL_VERB:-build}" -c opt \
  ${build_opts[@]+"${build_opts[@]}"} "${common[@]}" "${trace[@]}" \
  ${flags[@]+"${flags[@]}"} "${targets[@]}"
