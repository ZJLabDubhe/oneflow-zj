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
#include "oneflow/core/eager/blob_instruction_type.h"
#include "oneflow/core/vm/cpu_stream_type.h"

namespace oneflow {
namespace eager {
class CpuLazyReferenceInstructionType : public LazyReferenceInstructionType {
 public:
  CpuLazyReferenceInstructionType() = default;
  ~CpuLazyReferenceInstructionType() override = default;

  using stream_type = vm::CpuStreamType;
};

COMMAND(vm::RegisterInstructionType<CpuLazyReferenceInstructionType>("cpu.LazyReference"));

class CpuWriteBlobByCallbackInstructionType final : public WriteBlobByCallbackInstructionType {
 public:
  CpuWriteBlobByCallbackInstructionType() = default;
  ~CpuWriteBlobByCallbackInstructionType() override = default;

  using stream_type = vm::CpuStreamType;
};
COMMAND(
    vm::RegisterInstructionType<CpuWriteBlobByCallbackInstructionType>("cpu.WriteBlobByCallback"));

}  // namespace eager
}  // namespace oneflow
