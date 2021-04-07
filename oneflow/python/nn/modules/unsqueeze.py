"""
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
"""
import oneflow as flow
from oneflow.python.nn.module import Module
from oneflow.python.oneflow_export import oneflow_export
from oneflow.python.framework.tensor import register_tensor_op_by_module
from oneflow.python.framework.tensor import register_op_by_module


@oneflow_export("nn.Unsqueeze")
@register_tensor_op_by_module("unsqueeze")
@register_op_by_module("unsqueeze")
class Unsqueeze(Module):

    def __init__(self) -> None:
        super().__init__()
        self._op = (
            flow.builtin_op("expand_dims")
            .Input("in")
            .Output("out")
        )

    def forward(self, input, axis=0):
        assert axis<=len(input.size()), "axis should <= length of input tensor!"
        self._op = self._op.Attr("axis", axis).Build()
        return self._op(input)[0]
