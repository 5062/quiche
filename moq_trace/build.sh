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
# Toolchain locations default to the Nix development shell used for this fork.
# Override them with the MOQ_TRACE_* environment variables.
set -euo pipefail

# pkg-config, the compiler, and the bazel wrapper come from the moq-trace2
# development shell, so re-exec inside it when they are not on PATH.
MOQ_TRACE2_SRC=${MOQ_TRACE2_SRC:-$(cd "$(dirname "$0")/../.." && pwd)/moq-trace2}
if [ "${MOQ_TRACE_IN_DEVSHELL:-0}" != 1 ] && ! command -v pkg-config >/dev/null 2>&1; then
  export MOQ_TRACE_IN_DEVSHELL=1
  exec nix --extra-experimental-features 'nix-command flakes' develop \
    "$MOQ_TRACE2_SRC" --command bash "${BASH_SOURCE[0]}" "$@"
fi

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
  targets=(//quiche:moqt_relay)
fi

CLANG=${MOQ_TRACE_CLANG:-/nix/store/874j5xydsj6nr6i1zdrjvhln5gmxvvrr-clang-wrapper-21.1.8}
BAZELISK=${MOQ_TRACE_BAZELISK:-/nix/store/bnxk2g7srfbmm0ghhlzimkzshpwls211-bazelisk-1.28.1/bin/bazelisk}
ICU_DEV=${MOQ_TRACE_ICU_DEV:-/nix/store/4dn9hz9kl3fvcr4y09n6vdr302bldwcj-icu4c-76.1-dev}
ICU_LIB=${MOQ_TRACE_ICU_LIB:-/nix/store/clpq5c7bysml4vqpa1x60a5yk3nzkfj4-icu4c-76.1}

# The provider archives and headers are a build product of the moq-trace2
# checkout, so they are consumed from its install prefix instead of being copied
# here, where a snapshot would drift from the schemas the analyzer reads. Point
# MOQ_TRACE_PREFIX at a different prefix, or regenerate this one with:
#   cmake --install ~/moq-trace2/target/cmake --prefix <prefix> \
#     --component moq_trace --component quic_trace
TRACE_PREFIX=${MOQ_TRACE_PREFIX:-$MOQ_TRACE2_SRC/target/install}

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
elif [ ! -f "$TRACE_PREFIX/lib/libmoq_trace_provider.a" ]; then
  echo "no trace provider in $TRACE_PREFIX; build and install moq-trace2 first" >&2
  exit 1
else
  echo "trace prefix: $TRACE_PREFIX" >&2
fi

cd "$worktree"
export CC="$CLANG"/bin/clang
export CXX="$CLANG"/bin/clang++
export CPLUS_INCLUDE_PATH="$ICU_DEV"/include:"$TRACE_PREFIX"/include

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
