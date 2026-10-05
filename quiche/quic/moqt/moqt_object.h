// Copyright 2024 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef QUICHE_QUIC_MOQT_MOQT_OBJECT_H_
#define QUICHE_QUIC_MOQT_MOQT_OBJECT_H_

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "absl/base/thread_annotations.h"
#include "absl/strings/cord.h"
#include "absl/strings/string_view.h"
#include "absl/synchronization/mutex.h"
#include "quiche/quic/core/quic_time.h"
#include "quiche/quic/moqt/moqt_priority.h"
#include "quiche/quic/moqt/moqt_types.h"
#include "quiche/common/quiche_cord_utils.h"
#include "quiche/common/quiche_mem_slice.h"

#if defined(QUICHE_MOQ_TRACE)
#include <moq_trace/trace.hpp>
#endif

namespace moqt {

struct PublishedObjectMetadata {
  Location location;
  std::optional<uint64_t> subgroup;  // nullopt for datagrams.
  std::string extensions;
  MoqtObjectStatus status = MoqtObjectStatus::kNormal;
  MoqtPriority publisher_priority = kDefaultPublisherPriority;
  // The length of the entire payload, which might include data that is not
  // present in an encompassing PublishedObject or CachedObject.
  uint64_t payload_length;
  quic::QuicTime arrival_time = quic::QuicTime::Zero();
#if defined(QUICHE_MOQ_TRACE)
  // The relay cache assigns this sidecar identity through its const visitor
  // interface when it accepts the first fragment.
  mutable std::optional<moq_trace::LogicalId> trace_logical_id;
  // The relay cache records when it finished storing a fragment, before it
  // notifies listeners. Listener fan-out runs synchronously inside the same
  // call, and this timestamp keeps that work out of the inbound object phases.
  mutable std::optional<uint64_t> trace_stored_ns;
  // When the relay cache first made the object readable, on the trace clock.
  // Each outbound copy's delivery wait runs from here until its clone starts.
  mutable std::optional<uint64_t> trace_ready_ns;
#endif
  bool IsMalformed(const PublishedObjectMetadata& other,
                   bool ignore_status = false) const {
    // Arrival time can differ. Ignore placeholder status for partial objects.
    return (location != other.location || subgroup != other.subgroup ||
            (!ignore_status && status != other.status) ||
            publisher_priority != other.publisher_priority);
  }
  bool operator==(const PublishedObjectMetadata& other) const = default;
};

// PublishedObject is a description of an object that is sufficient to publish
// it on a given track.
struct PublishedObject {
  PublishedObjectMetadata metadata;
  // This could be a partial object, containing the data between the requested
  // offset and the end of the data the publisher has on hand.
  std::vector<quiche::QuicheMemSlice> payload;
  bool fin_after_this = false;
};

// CachedObject is a version of PublishedObject with a reference counted
// payload. This is thread-safe.
// TODO(martinduke): Allow for the deletion of the front of the payload. The
// number of bytes deleted will have to be subtracted from any offset that the
// caller provides (as well as added in payload_received).
class CachedObject {
 public:
  CachedObject(const PublishedObjectMetadata& metadata,
               quiche::QuicheMemSlice payload, bool fin_after_this)
      : metadata_(metadata),
        payload_(quiche::MemSliceToCord(std::move(payload))),
        fin_after_this_(fin_after_this) {}

  // Add |payload| at |offset|. Checks for overlaps in data. Returns false if
  // the payload is too large, or there is no new data.
  bool Append(uint64_t offset, absl::string_view payload);
  // Commit the final status and FIN of a complete payload before notifying
  // readers.
  void Complete(MoqtObjectStatus status, bool fin_after_this);
  // Returns a PublishedObject with only the portion of payload starting at
  // |offset|.
  PublishedObject ToPublishedObject(uint64_t offset = 0) const;
  // Snapshot metadata under the payload lock, including its finalized status.
  PublishedObjectMetadata metadata() const {
    absl::MutexLock lock(mutex_);
    return metadata_;
  }
#if defined(QUICHE_MOQ_TRACE)
  // Assign the cache's logical identity, and the instant the object became
  // readable, before notifying any listener of its first fragment.
  void SetTraceIdentity(moq_trace::LogicalId logical_id, uint64_t ready_ns) {
    absl::MutexLock lock(mutex_);
    metadata_.trace_logical_id = logical_id;
    metadata_.trace_ready_ns = ready_ns;
  }
#endif
  bool fin_after_this() const ABSL_LOCKS_EXCLUDED(mutex_) {
    absl::MutexLock lock(mutex_);
    return fin_after_this_;
  }
  void set_fin_after_this(bool fin) {
    absl::MutexLock lock(mutex_);
    fin_after_this_ = fin;
  }
  // This function wraps payload_.size(), both for Mutex purposes, and because
  // eventually it will account for memory blocks that have been freed from the
  // front of the payload.
  uint64_t payload_received() const {
    absl::MutexLock lock(mutex_);
    return payload_received_locked();
  }
  // Returns true if data in payload_ starting at |offset| is equal to
  // |payload|, checking only until the offset where one of the two strings
  // ends. Returns true if there is no overlap in the offsets.
  bool OverlapIsEqual(uint64_t offset, absl::string_view payload) const;

 private:
  // TODO(martinduke): Account for memory blocks that have been freed from the
  // front of the payload.
  uint64_t payload_received_locked() const { return payload_.size(); }

  mutable absl::Mutex mutex_;
  PublishedObjectMetadata ABSL_GUARDED_BY(mutex_) metadata_;
  absl::Cord payload_;
  // If true, this is the last object before FIN.
  bool ABSL_GUARDED_BY(mutex_) fin_after_this_;
};

}  // namespace moqt

#endif  // QUICHE_QUIC_MOQT_MOQT_OBJECT_H_
