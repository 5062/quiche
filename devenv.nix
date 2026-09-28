{ pkgs, config, ... }:

# Toolchain for the MoQ trace workflow in MOQ_TRACE.md. The scripts under
# moq_trace/ find Clang, Bazel, and ICU on PATH or through pkg-config, and the
# traced configuration additionally needs the installed moq_trace pkg-config
# package. This environment supplies all of them.
{
  packages = [
    pkgs.bazelisk
    pkgs.clang
    pkgs.git
    pkgs.icu
    pkgs.lttng-ust
    pkgs.pkg-config
    pkgs.python3
  ];

  # Nix splits ICU into outputs, and its pkg-config libdir names the dev output,
  # which holds no libraries. Name both locations directly.
  env.MOQ_TRACE_ICU_INCLUDE = "${pkgs.icu.dev}/include";
  env.MOQ_TRACE_ICU_LIBDIR = "${pkgs.icu.out}/lib";

  # The moq_trace package is the CMake install of the sibling toolkit checkout.
  # Point MOQ_TRACE_PREFIX elsewhere to use a different install.
  enterShell = ''
    export MOQ_TRACE_PREFIX="''${MOQ_TRACE_PREFIX:-${config.devenv.root}/../moq-trace2/target/install}"
    export PKG_CONFIG_PATH="$MOQ_TRACE_PREFIX/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    if ! pkg-config --exists moq_trace; then
      echo "moq_trace pkg-config package not found under $MOQ_TRACE_PREFIX" >&2
      echo "Install it from moq-trace2 with cmake --install, or set MOQ_TRACE_PREFIX." >&2
    fi
  '';
}
