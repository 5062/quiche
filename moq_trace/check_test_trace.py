"""Verify the emitted packet and socket events from test_trace.sh's fixtures."""

import collections
import pathlib
import sys

import bt2


def check_trace(path: pathlib.Path) -> None:
    """Check actual provider emissions, including GSO and partial batch sends."""
    starts = {}
    ends = {}
    phases = {}
    socket_stats = collections.Counter()
    dropped_rx = 0
    # Packet phase 9 is read_queue and 10 is send_queue in the provider
    # contract. Each records (start, end) per packet.
    queues = collections.defaultdict(list)
    phase_names = {}
    outcomes = {}
    paths = 0
    for message in bt2.TraceCollectionMessageIterator(str(path)):
        if not isinstance(message, bt2._EventMessageConst):
            continue
        event = message.event
        if not event.name.startswith("quic_trace:"):
            continue
        name = event.name.removeprefix("quic_trace:")
        fields = event.payload_field
        if name == "quic_connection_path":
            # A path names a connection's addresses rather than a lifecycle.
            assert int(fields["connection_id"]) > 0
            paths += 1
            continue
        key = (int(event.common_context_field["vpid"]), int(fields["trace_id"]))
        if name in ("quic_packet_start", "udp_socket_start"):
            assert key not in starts, f"duplicate start: {key}"
            starts[key] = (name, int(fields["timestamp_ns"]), int(fields["direction"]))
        elif name in ("quic_packet_end", "udp_socket_end"):
            assert key not in ends, f"duplicate end: {key}"
            ends[key] = (name, int(fields["timestamp_ns"]))
            if name == "udp_socket_end":
                socket_stats[
                    tuple(
                        int(fields[field])
                        for field in ("outcome", "buffers", "datagrams", "bytes")
                    )
                ] += 1
            else:
                outcomes[key] = int(fields["outcome"])
                # Packet outcome 4 is abandonment, which is never expected here.
                assert int(fields["outcome"]) != 4, f"abandoned packet: {key}"
                assert int(fields["has_byte_len"]) == 1
                assert int(fields["byte_len"]) > 0
                if starts[key][2] == 0 and int(fields["outcome"]) == 3:
                    dropped_rx += 1
        elif name == "quic_packet_phase":
            phase_key = (*key, int(fields["span_id"]))
            edge = int(fields["edge"])
            if edge == 0:
                assert phase_key not in phases, f"duplicate phase: {phase_key}"
                phases[phase_key] = int(fields["timestamp_ns"])
                phase_names[phase_key] = int(fields["phase"])
            else:
                assert phase_key in phases, f"phase without start: {phase_key}"
                start_ns = phases.pop(phase_key)
                end_ns = int(fields["timestamp_ns"])
                assert end_ns >= start_ns
                phase = phase_names.pop(phase_key)
                if phase in (9, 10):
                    queues[key].append((phase, start_ns, end_ns))

    assert starts.keys() == ends.keys(), "unmatched packet or socket lifecycle"
    assert not phases, "unmatched packet phases"
    for key, (name, start_ns, _) in starts.items():
        end_name, end_ns = ends[key]
        assert end_name == name.replace("_start", "_end")
        assert end_ns >= start_ns, f"negative lifecycle: {key}"
    # Socket-bounded lifecycles: a successful RX packet starts its one
    # read_queue at its start, and a successful TX packet ends its one
    # send_queue at its end.
    checked = 0
    for key, outcome in outcomes.items():
        name, start_ns, direction = starts[key]
        if name != "quic_packet_start" or outcome != 0:
            continue
        phase, edge_ns = (9, start_ns) if direction == 0 else (10, ends[key][1])
        matching = [queue for queue in queues[key] if queue[0] == phase]
        assert len(matching) == 1, f"packet {key} has {len(matching)} queue phases"
        boundary = matching[0][1] if direction == 0 else matching[0][2]
        assert boundary == edge_ns, f"packet {key} queue phase is off its boundary"
        checked += 1
    assert checked > 0, "no successful packet was checked for its queue phase"
    assert paths > 0, "no connection path was recorded"
    assert dropped_rx > 0, "duplicate packet fixture emitted no dropped RX packet"
    # Outcome 0 is success and 2 is would_block in the current provider contract.
    expected = collections.Counter(
        {
            (0, 1, 2, 1100): 1,  # One GSO buffer, two datagrams and a shorter tail.
            (0, 2, 2, 300): 1,  # External sendmmsg flush of both queued buffers.
            (0, 1, 1, 100): 1,  # First buffer accepted by a partial sendmmsg.
            (2, 0, 0, 0): 1,  # Remaining buffer would block.
            (0, 1, 1, 200): 1,  # Retry sends only the remaining buffer.
        }
    )
    assert socket_stats == expected, (
        f"socket stats: {socket_stats}, expected {expected}"
    )
    print(
        f"Verified {len(starts)} lifecycles, {checked} socket-bounded packets, "
        f"{paths} connection paths, and all batch socket counts"
    )


if __name__ == "__main__":
    check_trace(pathlib.Path(sys.argv[1]))
