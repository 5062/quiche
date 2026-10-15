// Copyright 2026 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <sys/socket.h>

#include <cerrno>
#include <tuple>
#include <vector>

#include "quiche/common/quiche_circular_deque.h"
#include "quiche/quic/core/quic_linux_socket_utils.h"
#include "quiche/quic/core/quic_trace_utils.h"
#include "quiche/quic/core/quic_udp_socket.h"
#include "quiche/quic/platform/api/quic_test.h"
#include "quiche/quic/test_tools/quic_mock_syscall_wrapper.h"

namespace {
bool intercept_sendmsg = false;
int attempts = 0;
int interruptions = 0;
int terminal_error = 0;
constexpr int kBytes = 8;
int SendResult() {
  if (attempts++ < interruptions) {
    errno = EINTR;
    return -1;
  }
  errno = terminal_error;
  return terminal_error ? -1 : kBytes;
}
#if defined(QUICHE_MOQ_TRACE)
bool recording = false;
std::vector<struct quic_trace_udp_socket_start> starts;
std::vector<struct quic_trace_udp_socket_end> ends;
#endif
}  // namespace

// POSIX uses sendmsg directly; Linux batch writers use QuicSyscallWrapper.
extern "C" ssize_t __real_sendmsg(int, const msghdr*, int);
extern "C" ssize_t __wrap_sendmsg(int fd, const msghdr* hdr, int flags) {
  return intercept_sendmsg ? SendResult() : __real_sendmsg(fd, hdr, flags);
}
#if defined(QUICHE_MOQ_TRACE)
// Observe the real facade without depending on a live LTTng session.
extern "C" bool __real_quic_trace_udp_socket_start_enabled();
extern "C" bool __wrap_quic_trace_udp_socket_start_enabled() {
  return recording || __real_quic_trace_udp_socket_start_enabled();
}
extern "C" bool __real_quic_trace_udp_socket_end_enabled();
extern "C" bool __wrap_quic_trace_udp_socket_end_enabled() {
  return recording || __real_quic_trace_udp_socket_end_enabled();
}
extern "C" void __real_quic_trace_udp_socket_start(
    const struct quic_trace_udp_socket_start*);
extern "C" void __wrap_quic_trace_udp_socket_start(
    const struct quic_trace_udp_socket_start* event) {
  if (recording)
    starts.push_back(*event);
  else
    __real_quic_trace_udp_socket_start(event);
}
extern "C" void __real_quic_trace_udp_socket_end(
    const struct quic_trace_udp_socket_end*);
extern "C" void __wrap_quic_trace_udp_socket_end(
    const struct quic_trace_udp_socket_end* event) {
  if (recording)
    ends.push_back(*event);
  else
    __real_quic_trace_udp_socket_end(event);
}
#endif

namespace quic::test {
namespace {
enum class SendPath { kLinuxPacket, kLinuxBatch, kPosixPacket };
class QuicSocketTraceTest
    : public QuicTest,
      public testing::WithParamInterface<std::tuple<SendPath, int, int>> {
 protected:
  void SetUp() override {
    QuicTest::SetUp();
    attempts = 0;
    interruptions = std::get<1>(GetParam());
    terminal_error = std::get<2>(GetParam());
#if defined(QUICHE_MOQ_TRACE)
    starts.clear();
    ends.clear();
    recording = true;
#endif
  }
  void TearDown() override {
    intercept_sendmsg = false;
#if defined(QUICHE_MOQ_TRACE)
    recording = false;
#endif
    QuicTest::TearDown();
  }
};
TEST_P(QuicSocketTraceTest, RecordsEachInterruptedSend) {
  using testing::_;
  const auto path = std::get<0>(GetParam());
  char payload[kBytes]{};
  MockQuicSyscallWrapper syscalls;
  ScopedGlobalSyscallWrapperOverride override(&syscalls);
  WriteResult result;
  if (path == SendPath::kLinuxPacket) {
    EXPECT_CALL(syscalls, Sendmsg(_, _, _))
        .Times(interruptions + 1)
        .WillRepeatedly([](auto...) { return SendResult(); });
    iovec iov{payload, sizeof(payload)};
    QuicMsgHdr hdr(&iov, 1, nullptr, 0);
    result = QuicLinuxSocketUtils::WritePacket(42, hdr, true);
  } else if (path == SendPath::kLinuxBatch) {
    EXPECT_CALL(syscalls, Sendmmsg(_, _, 2, _))
        .Times(interruptions + 1)
        .WillRepeatedly([](int, mmsghdr* msgs, unsigned, int) {
          if (SendResult() < 0) return -1;
          msgs[0].msg_len = kBytes;
          return 1;  // A partial batch accepts only its first datagram.
        });
    quiche::QuicheCircularDeque<BufferedWrite> writes;
    const QuicSocketAddress peer(QuicIpAddress::Loopback4(), 1234);
    writes.emplace_back(payload, sizeof(payload), QuicIpAddress(), peer);
    writes.emplace_back(payload, sizeof(payload), QuicIpAddress(), peer);
    QuicMMsgHdr hdr(writes.begin(), writes.end(), 0);
    int sent = -1;
    result = QuicLinuxSocketUtils::WriteMultiplePackets(42, &hdr, &sent);
    EXPECT_EQ(sent, terminal_error ? 0 : 1);
  } else {
    intercept_sendmsg = true;
    QuicUdpPacketInfo info;
    info.SetPeerAddress(QuicSocketAddress(QuicIpAddress::Loopback4(), 1234));
    result = QuicUdpSocketApi().WritePacket(42, payload, sizeof(payload), info);
    intercept_sendmsg = false;
  }
  EXPECT_EQ(attempts, interruptions + 1);
  EXPECT_EQ(errno, terminal_error);
  const bool blocked =
      terminal_error == EAGAIN ||
      (path == SendPath::kLinuxPacket && terminal_error == ENOBUFS);
  EXPECT_EQ(result.status,
            terminal_error == 0
                ? WRITE_STATUS_OK
                : (blocked ? WRITE_STATUS_BLOCKED : WRITE_STATUS_ERROR));
  if (terminal_error)
    EXPECT_EQ(result.error_code, terminal_error);
  else
    EXPECT_EQ(result.bytes_written, kBytes);
#if defined(QUICHE_MOQ_TRACE)
  ASSERT_EQ(starts.size(), interruptions + 1);
  ASSERT_EQ(ends.size(), starts.size());
  for (size_t i = 0; i < ends.size(); ++i) {
    EXPECT_EQ(starts[i].trace_id, ends[i].trace_id);
    EXPECT_LE(starts[i].timestamp_ns, ends[i].timestamp_ns);
    if (i > 0) EXPECT_LE(ends[i - 1].timestamp_ns, starts[i].timestamp_ns);
    const bool accepted = i == ends.size() - 1 && terminal_error == 0;
    const auto outcome = i == ends.size() - 1 && terminal_error == EAGAIN
                             ? QUIC_TRACE_SOCKET_OUTCOME_WOULD_BLOCK
                             : (accepted ? QUIC_TRACE_SOCKET_OUTCOME_SUCCESS
                                         : QUIC_TRACE_SOCKET_OUTCOME_ERROR);
    EXPECT_EQ(ends[i].outcome, outcome);
    EXPECT_EQ(ends[i].buffers, accepted ? 1 : 0);
    EXPECT_EQ(ends[i].datagrams, accepted ? 1 : 0);
    EXPECT_EQ(ends[i].bytes, accepted ? kBytes : 0);
  }
  ASSERT_TRUE(result.quic_trace_sent_ns.has_value());
  EXPECT_EQ(*result.quic_trace_sent_ns, ends.back().timestamp_ns);
#endif
}
INSTANTIATE_TEST_SUITE_P(
    SendPaths, QuicSocketTraceTest,
    testing::Combine(testing::Values(SendPath::kLinuxPacket,
                                     SendPath::kLinuxBatch,
                                     SendPath::kPosixPacket),
                     testing::Values(1, 2),
                     testing::Values(0, EAGAIN, ENOBUFS, EIO)));
}  // namespace
}  // namespace quic::test
