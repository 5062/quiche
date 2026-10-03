#ifndef QUICHE_QUIC_CORE_MOQ_TRACE_UTILS_H_
#define QUICHE_QUIC_CORE_MOQ_TRACE_UTILS_H_

#if defined(QUICHE_MOQ_TRACE)

#include <cerrno>
#include <optional>
#include <quic_trace/trace.hpp>

#include "quiche/quic/core/quic_packets.h"
#include "quiche/quic/core/quic_types.h"

namespace quic {

// Translate a completed send's errno, with ENOBUFS policy chosen by the writer.
inline quic_trace_socket_outcome MoqTraceSocketOutcome(
    int error, bool enobufs_blocked = false) {
  if (error == 0) {
    return QUIC_TRACE_SOCKET_OUTCOME_SUCCESS;
  }
  if (error == EAGAIN || error == EWOULDBLOCK ||
      (error == ENOBUFS && enobufs_blocked)) {
    return QUIC_TRACE_SOCKET_OUTCOME_WOULD_BLOCK;
  }
  if (error == ECONNRESET) {
    return QUIC_TRACE_SOCKET_OUTCOME_CONNECTION_RESET;
  }
  return QUIC_TRACE_SOCKET_OUTCOME_ERROR;
}

// Map the encryption level to the shared provider's packet-space enum.
inline quic_trace_packet_space MoqTracePacketSpace(EncryptionLevel level) {
  switch (level) {
    case ENCRYPTION_INITIAL:
      return QUIC_TRACE_PACKET_SPACE_INITIAL;
    case ENCRYPTION_HANDSHAKE:
      return QUIC_TRACE_PACKET_SPACE_HANDSHAKE;
    case ENCRYPTION_ZERO_RTT:
      return QUIC_TRACE_PACKET_SPACE_ZERO_RTT;
    case ENCRYPTION_FORWARD_SECURE:
      return QUIC_TRACE_PACKET_SPACE_DATA;
    case NUM_ENCRYPTION_LEVELS:
      break;
  }
  return QUIC_TRACE_PACKET_SPACE_DATA;
}

// Non-data long headers carry no packet number space.
inline std::optional<quic_trace_packet_space> MoqTracePacketSpace(
    const QuicPacketHeader& header) {
  if (header.form == IETF_QUIC_SHORT_HEADER_PACKET) {
    return QUIC_TRACE_PACKET_SPACE_DATA;
  }
  switch (header.long_packet_type) {
    case INITIAL:
      return QUIC_TRACE_PACKET_SPACE_INITIAL;
    case HANDSHAKE:
      return QUIC_TRACE_PACKET_SPACE_HANDSHAKE;
    case ZERO_RTT_PROTECTED:
      return QUIC_TRACE_PACKET_SPACE_ZERO_RTT;
    default:
      return std::nullopt;
  }
}

}  // namespace quic

#endif  // defined(QUICHE_MOQ_TRACE)

#endif  // QUICHE_QUIC_CORE_MOQ_TRACE_UTILS_H_
