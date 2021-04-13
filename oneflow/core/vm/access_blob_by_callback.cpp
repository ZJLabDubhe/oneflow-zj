/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow/core/vm/instruction_type.h"
#include "oneflow/core/vm/instruction.msg.h"
#include "oneflow/core/vm/access_blob_arg_cb_phy_instr_operand.h"
#include "oneflow/core/vm/host_stream_type.h"
#include "oneflow/core/register/ofblob.h"
#include "oneflow/core/eager/eager_blob_object.h"
#include "oneflow/core/vm/stream.msg.h"

namespace oneflow {
namespace vm {

class WriteBlobByCallback final : public InstructionType {
 public:
  WriteBlobByCallback() = default;
  ~WriteBlobByCallback() override = default;

  using stream_type = vm::HostStreamType;

  void Compute(Instruction* instruction) const override {
    const InstructionMsg& instr_msg = instruction->instr_msg();
    const auto& phy_instr_operand = instr_msg.phy_instr_operand();
    CHECK(static_cast<bool>(phy_instr_operand));
    const auto* ptr = dynamic_cast<const WriteBlobArgCbPhyInstrOperand*>(phy_instr_operand.get());
    CHECK_NOTNULL(ptr);
    DeviceCtx* device_ctx = instruction->stream().device_ctx().get();
    OfBlob ofblob(device_ctx, ptr->eager_blob_object()->mut_blob());
    ptr->callback()(reinterpret_cast<uint64_t>(&ofblob));
  }

  void Infer(Instruction* instruction) const override { /* do nothing */
  }
};
COMMAND(vm::RegisterInstructionType<WriteBlobByCallback>("WriteBlobByCallback"));

}  // namespace vm
}  // namespace oneflow
