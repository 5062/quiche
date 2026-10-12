#ifndef QUICHE_QUIC_CORE_QUIC_TRACE_UTILS_H_
#define QUICHE_QUIC_CORE_QUIC_TRACE_UTILS_H_

#if defined(QUICHE_MOQ_TRACE)

#include <optional>
#include <quic_trace/trace.hpp>

#include "quiche/quic/core/quic_packets.h"
#include "quiche/quic/core/quic_types.h"
#include "quiche/quic/platform/api/quic_socket_address.h"

namespace quic {

// Describe one end of a connection path for `quic_connection_path`. An
// uninitialized address, such as a wildcard the stack never resolved, is
// recorded as the unspecified IPv6 address with its port.
inline quic_trace::PathEndpoint QuicTracePathEndpoint(const QuicIpAddress& host,
                                                      uint16_t port) {
  if (!host.IsInitialized()) {
    return quic_trace::PathEndpoint::ipv6({}, port);
  }
  const sockaddr_storage address = QuicSocketAddress(host, port).generic_address();
  return quic_trace::PathEndpoint::from_sockaddr(
      reinterpret_cast<const sockaddr*>(&address));
}

// Map the encryption level to the shared provider's packet-space enum.
inline quic_trace_packet_space QuicTracePacketSpace(EncryptionLevel level) {
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
inline std::optional<quic_trace_packet_space> QuicTracePacketSpace(
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

#endif  // QUICHE_QUIC_CORE_QUIC_TRACE_UTILS_H_
