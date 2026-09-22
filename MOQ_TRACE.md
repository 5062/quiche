# MoQ draft-16 trace instrumentation

This fork adds LTTng-UST tracepoints for MoQ per-object relay processing to
Google QUICHE, in both the MoQ layer and the QUIC transport layer. It is a local
measurement fork: it is not intended for upstream submission and is not part of
any product build.

## Revision

The instrumented branch starts at `2b79d575776fe8c9028e83ce4dc41e5e1f81ba7b`
(2026-06-02), the last revision that implements the draft-16 control plane and
wire format:

- `kDefaultMoqtVersion` is `moqt-16`.
- Client and server SETUP are the dedicated control messages `0x20` and `0x21`.
- Object identifiers and the fields that precede them are QUIC-style varints.

The revision that most recently advertises `moqt-16` in ALPN, `d5bf62fc4`, cannot
be used. It already implements the draft-17 control plane (`kSetup` `0x2f00` on a
uni stream) and the draft-18 EBML-style `moq_varint` encoding. Adding `moqt-16` to
its ALPN list would negotiate draft-18 bytes under a draft-16 label and the peer
would decode nothing, so the negotiated version would misdescribe the wire rather
than select a compatibility mode. Real dual-version support would be a second
protocol implementation, not an instrumentation change.

## What the instrumentation emits

MoQ object lifecycles, one event stream per logical object:

| Call site | Emission |
| --- | --- |
| `MoqtDataParser::ParseNextItemFromStream`, `kObjectId` | object start, header parse phase |
| `IncomingDataStream::OnObjectMessage` | create phase on the first fragment, frame commit phase on the last, payload read phase per fragment |
| `IncomingDataStream::OnObjectPayloadConsumed` | payload read and object end, per fragment or once per object |
| `OutgoingSubgroupStream::SendObjects` | clone phase, one TX object per subscriber copy |
| `OutgoingUniStream::WriteObjectToStream` | header encode phase, payload write phase |

Transport lifecycles, taken from the shared QUIC core rather than from MoQ aware
code:

| Call site | Emission |
| --- | --- |
| `QuicConnection::OnPacket`, `QuicConnection::FinishMoqTracePacket` | RX packet start and end, with the outcome |
| `QuicConnection` public header, header unprotect, payload decrypt, frame processing | RX packet phases `header_parse`, `header_unprotect`, `payload_decrypt`, `frame_process` |
| `QuicConnection::OnStreamFrame` | STREAM frame byte range and FIN |
| `QuicPacketCreator::CreateAndSerializeStreamFrame`, `CreateAndSerializePacket` | TX packet start and end, phases `frame_encode` and `packet_encrypt` |
| `QuicPacketReader::ReadAndDispatchPackets`, `QuicConnection` socket reads and writes | UDP socket start and end with buffer, datagram, and byte counts |

No sampling is applied. Analysis selects the packets that carry the objects it
measures.

## Identity and fragmentation contract

- Every `QuicConnection` allocates a process-wide monotonic connection ID and
  exposes it to its `MoqtSession`. Wire connection IDs rotate and are
  variable-length, so they cannot serve as the join key.
- The relay allocates one logical object identity when an object first enters the
  cache, keyed by full track name, group, subgroup, and object. Every later
  fragment and every downstream copy carries that identity. Wire aliases differ
  between the upstream and the downstream session and cannot be the join key.
- One RX lifecycle describes one logical object. One TX lifecycle describes one
  subscriber copy. A fragment or a partial write is a repeated phase interval
  inside the lifecycle, not a separate lifecycle, so copy counts stay exact.
- MOQT datagram objects are out of scope. The transport contract correlates
  objects through STREAM byte ranges and there is no QUIC DATAGRAM frame event, so
  only streamed subgroup objects are measured.

## Build integration

The hooks compile behind `QUICHE_MOQ_TRACE` and need the C++ facade headers and
the two provider archives from `moq-trace2`. Bazel cannot depend on a path outside
the execution root, so they arrive through `--cxxopt`, `--linkopt`, and
`CPLUS_INCLUDE_PATH`:

```sh
moq_trace/build.sh                         # traced build of //quiche:moqt_relay
TRACE=0 moq_trace/build.sh                 # same sources, hooks compiled out
TRACE=0 moq_trace/test.sh                  # the MoQ test targets, hooks off
moq_trace/capture.sh moq_trace/artifacts/capture ./bazel-bin/quiche/moqt_relay loopback
moq_trace/analyze.sh moq_trace/artifacts/capture/session \
  --output moq_trace/artifacts/capture/out.duckdb \
  --object-size 4096 --subscribers 1 --pid <relay pid printed by capture.sh>
```

Each script re-executes itself inside the `moq-trace2` development shell when its
tools are not already on `PATH`, so the checkout is the only thing to open. Set
`MOQ_TRACE2_SRC` when the two repositories are not siblings.

Options are collected wherever they appear and the first argument that names a
directory is the worktree, so `moq_trace/test.sh . --jobs=8` tests this checkout
and `moq_trace/test.sh --jobs=8` tests the checkout that holds the script. An
option is never mistaken for a target, and `moq_trace/build.sh` and
`moq_trace/test.sh` fall back to their own checkout and to their default targets.
Set `MOQ_TRACE_OUTBASE` to a second Bazel output base when the traced and
untraced configurations should both stay compiled: each run otherwise
invalidates the other one's objects, and the alternate base leaves the workspace
`bazel-*` symlinks pointing at the traced binary.

`capture.sh` starts the relay under LTTng, drives it with the `moq-bench` peers
from `moq-trace2`, decodes the capture with Babeltrace 2, and prints the relay pid
and the matching analysis command. It mints a throwaway certificate into the
output directory unless `MOQ_TRACE_CERT` and `MOQ_TRACE_KEY` name an existing
pair, so a capture needs nothing left over from an earlier run.

Traced builds require Linux and LTTng-UST. A build without the macro compiles the
modified sources with no trace code and no new link dependencies. The provider
archives are consumed from `moq-trace2/target/install` rather than copied here,
because a snapshot of them would drift from the schemas the analyzer reads; point
`MOQ_TRACE_PREFIX` at another prefix, or regenerate that one with
`cmake --install ~/moq-trace2/target/cmake --prefix <prefix> --component moq_trace
--component quic_trace`. The compiler, bazel, and ICU paths default to the local
Nix shell and can be overridden with the `MOQ_TRACE_*` environment variables.

Build output, Bazel convenience symlinks, and `moq_trace/artifacts` are ignored by
git. The artifacts directory holds the traced relay binary under `bin/`, the test
logs under `logs/`, and one directory per capture with its CTF trace, decoded
events, DuckDB file, and peer logs.

## Bring-up fixes beyond instrumentation

Three fixes belong to this fork and are not tracepoints:

1. `MoqtControlMessageParser::ReadTrackNamespace` accepts an empty namespace when
   parsing a SUBSCRIBE_NAMESPACE prefix. Draft-16 section 9.25 allows an empty
   prefix and the benchmark peer sends one.
2. `MoqtRelay::MoqtRelay` assigns the resolved client event loop to
   `client_event_loop_`. Without it the relay keeps a null loop.
3. `MoqtRelayTrackPublisher::OnObjectFragment` tolerates a status change on an
   object that arrived in fragments. Draft-16 signals the end of a group with the
   stream FIN, so the fragment that completes an object carries `kEndOfGroup`
   while the earlier fragments of the same object carried the `kNormal`
   placeholder. The relay must not read that as a malformed track, and it must not
   advance track state before the payload is complete. Unit tested by
   `FragmentedObjectStatusIsKnownAtTheEnd`.

## Verification

```sh
moq_trace/build.sh
moq_trace/test.sh
TRACE=0 moq_trace/test.sh
moq_trace/capture.sh moq_trace/artifacts/capture ./bazel-bin/quiche/moqt_relay loopback
moq_trace/analyze.sh moq_trace/artifacts/capture/session \
  --output moq_trace/artifacts/capture/trace.duckdb \
  --object-size 4096 --subscribers 1 --pid <relay-vpid>
```

A six second traced loopback run through the relay reported 78 received groups
with no mismatches in the benchmark and produced 476 object start and end pairs
and 3246 packet start and end pairs. The analysis of the relay process resolved
119 inbound objects into exactly 119 outbound copies, with one `create` and one
`frame_commit` phase and four payload fragments each. It correlated every object
with the packets that carried it (238 coverage rows) and reported object, QUIC
object, packet, and socket metrics.

The ordinary configuration keeps the standard suite green: with the macro off,
the `//quiche:moqt_*_test` targets pass, and the built relay exports neither
`lttng_ust_tracepoint_ptr_*` symbols nor a `lttng_ust_tracepoints_ptrs` section.
