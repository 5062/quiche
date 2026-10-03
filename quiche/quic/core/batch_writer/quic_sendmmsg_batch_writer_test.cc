// Copyright (c) 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "quiche/quic/core/batch_writer/quic_sendmmsg_batch_writer.h"

#include <cerrno>
#include <memory>

#include "quiche/quic/platform/api/quic_test.h"
#include "quiche/quic/test_tools/quic_mock_syscall_wrapper.h"

namespace quic {
namespace test {
namespace {

class QuicSendmmsgBatchWriterTest : public QuicTest {
 protected:
  void BufferPackets(QuicSendmmsgBatchWriter& writer) {
    for (size_t length : {100u, 200u}) {
      ASSERT_EQ(
          WriteResult(WRITE_STATUS_OK, 0),
          writer.WritePacket(data_, length, QuicIpAddress::Any4(),
                             QuicSocketAddress(QuicIpAddress::Loopback4(), 443),
                             nullptr, QuicPacketWriterParams()));
    }
  }

  char data_[200] = {};
  testing::StrictMock<MockQuicSyscallWrapper> mock_syscalls_;
  ScopedGlobalSyscallWrapperOverride syscall_override_{&mock_syscalls_};
};

TEST_F(QuicSendmmsgBatchWriterTest, FlushBufferedPackets) {
  QuicSendmmsgBatchWriter writer(std::make_unique<QuicBatchWriterBuffer>(), -1);
  BufferPackets(writer);
  EXPECT_CALL(mock_syscalls_, Sendmmsg(testing::_, testing::_, 2, 0))
      .WillOnce([](int, mmsghdr* messages, unsigned int, int) {
        messages[0].msg_len = 100;
        messages[1].msg_len = 200;
        return 2;
      });
  EXPECT_EQ(WriteResult(WRITE_STATUS_OK, 300), writer.Flush());
  // An empty flush performs no socket operation.
  EXPECT_EQ(WriteResult(WRITE_STATUS_OK, 0), writer.Flush());
}

TEST_F(QuicSendmmsgBatchWriterTest, FlushPartialWriteWouldBlock) {
  QuicSendmmsgBatchWriter writer(std::make_unique<QuicBatchWriterBuffer>(), -1);
  BufferPackets(writer);
  testing::InSequence sequence;
  EXPECT_CALL(mock_syscalls_, Sendmmsg(testing::_, testing::_, 2, 0))
      .WillOnce([](int, mmsghdr* messages, unsigned int, int) {
        messages[0].msg_len = 100;
        return 1;
      });
  EXPECT_CALL(mock_syscalls_, Sendmmsg(testing::_, testing::_, 1, 0))
      .WillOnce(testing::SetErrnoAndReturn(EAGAIN, -1));
  EXPECT_EQ(WriteResult(WRITE_STATUS_BLOCKED, EAGAIN), writer.Flush());
  EXPECT_TRUE(writer.IsWriteBlocked());
  writer.SetWritable();
  EXPECT_CALL(mock_syscalls_, Sendmmsg(testing::_, testing::_, 1, 0))
      .WillOnce([](int, mmsghdr* messages, unsigned int, int) {
        messages[0].msg_len = 200;
        return 1;
      });
  EXPECT_EQ(WriteResult(WRITE_STATUS_OK, 200), writer.Flush());
}

}  // namespace
}  // namespace test
}  // namespace quic
