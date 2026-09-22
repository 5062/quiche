#ifndef QUICHE_QUIC_CORE_MOQ_TRACE_UTILS_H_
#define QUICHE_QUIC_CORE_MOQ_TRACE_UTILS_H_

#if defined(QUICHE_MOQ_TRACE)

#include <optional>

#include <quic_trace/trace.hpp>

#include "quiche/quic/core/quic_packets.h"
#include "quiche/quic/core/quic_types.h"

namespace quic {

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
