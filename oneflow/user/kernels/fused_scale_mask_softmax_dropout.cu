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
#include "oneflow/core/framework/framework.h"
#include "oneflow/core/cuda/softmax.cuh"
#include "oneflow/core/ep/cuda/cuda_stream.h"
#include "oneflow/user/kernels/fused_scale_mask_softmax.cuh"

namespace oneflow {

namespace {

template<typename SRC, typename DST>
struct DropoutLoad {
  DropoutLoad(const SRC* src, const bool* mask, int64_t row_size, SRC scale)
      : src(src), mask(mask), row_size(row_size), scale(scale) {}
  template<int N>
  __device__ void load(DST* dst, int64_t row, int64_t col) const {
    cuda::softmax::Pack<SRC, N> pack;
    const int64_t offset = (row * row_size + col) / N;
    pack.storage = *(reinterpret_cast<const cuda::softmax::PackType<SRC, N>*>(src) + offset);
    cuda::softmax::Pack<bool, N> mask_pack;
    mask_pack.storage = *(reinterpret_cast<const cuda::softmax::PackType<bool, N>*>(mask) + offset);
#pragma unroll
    for (int i = 0; i < N; ++i) {
      dst[i] = static_cast<DST>(pack.elem[i]) * static_cast<DST>(mask_pack.elem[i])
               * static_cast<DST>(scale);
    }
  }
  const SRC* src;
  const bool* mask;
  int64_t row_size;
  SRC scale;
};

template<typename SRC, typename DST>
struct DropoutStore {
  DropoutStore(DST* dst, DST* softmax_y, const bool* mask, int64_t row_size, DST scale)
      : dst(dst), softmax_y(softmax_y), mask(mask), row_size(row_size), scale(scale) {}
  template<int N>
  __device__ void store(const SRC* src, int64_t row, int64_t col) {
    cuda::softmax::Pack<DST, N> softmax_y_pack;
    cuda::softmax::Pack<DST, N> dst_pack;
    const int64_t offset = (row * row_size + col) / N;
    cuda::softmax::Pack<bool, N> mask_pack;
    mask_pack.storage = *(reinterpret_cast<const cuda::softmax::PackType<bool, N>*>(mask) + offset);
#pragma unroll
    for (int i = 0; i < N; ++i) {
      softmax_y_pack.elem[i] = static_cast<DST>(src[i]);
      dst_pack.elem[i] =
          static_cast<DST>(src[i]) * static_cast<DST>(mask_pack.elem[i]) * static_cast<DST>(scale);
    }
    *(reinterpret_cast<cuda::softmax::PackType<DST, N>*>(softmax_y) + offset) =
        softmax_y_pack.storage;
    *(reinterpret_cast<cuda::softmax::PackType<DST, N>*>(dst) + offset) = dst_pack.storage;
  }
  DST* dst;
  DST* softmax_y;
  const bool* mask;
  int64_t row_size;
  DST scale;
};

template<typename T, typename ComputeType, typename MASK, int num_dims>
void LaunchBroadcastForwardKernel(cudaStream_t stream, const T* x, T* y, T* softmax_y,
                                  const MASK* mask, const bool* dropout_mask,
                                  const int64_t elem_cnt, const int64_t rows, const int64_t cols,
                                  const float fill, const float scale, const float dropout_scale,
                                  const int64_t* input_dims, const int64_t* mask_dims) {
  DropoutStore<ComputeType, T> store(y, softmax_y, dropout_mask, cols, dropout_scale);
  NdIndexOffsetHelper<int32_t, num_dims> input_index_helper(input_dims);
  NdIndexOffsetHelper<int32_t, num_dims> mask_index_helper(mask_dims);
  fused_scale_mask_softmax::BroadcastMaskSoftmaxParams<num_dims, int32_t> params;
  params.src_index_helper = input_index_helper;
  params.mask_index_helper = mask_index_helper;
  params.mask_dims = mask_dims;
  params.row_size = cols;
  params.fill = fill;
  params.scale = scale;
  fused_scale_mask_softmax::BroadcastScaleMaskLoad<T, ComputeType, MASK, num_dims, int32_t> load(
      x, mask, params);
  OF_CUDA_CHECK((cuda::softmax::DispatchSoftmax<decltype(load), decltype(store), ComputeType>(
      stream, load, store, rows, cols)));
}

template<typename T, typename ComputeType, typename MASK>
void LaunchElementwiseForwardKernel(cudaStream_t stream, const T* x, T* y, T* softmax_y,
                                    const MASK* mask, const bool* dropout_mask, const int64_t rows,
                                    const int64_t cols, const float fill, const float scale,
                                    const float dropout_scale) {
  fused_scale_mask_softmax::ElementwiseMaskSoftmaxParams params;
  params.row_size = cols;
  params.fill = fill;
  params.scale = scale;
  fused_scale_mask_softmax::ElementwiseScaleMaskLoad<T, ComputeType, MASK> load(x, mask, params);
  DropoutStore<ComputeType, T> store(y, softmax_y, dropout_mask, cols, dropout_scale);
  OF_CUDA_CHECK((cuda::softmax::DispatchSoftmax<decltype(load), decltype(store), ComputeType>(
      stream, load, store, rows, cols)));
}

template<typename T, typename ComputeType, typename MASK, int num_dims>
void LaunchBroadcastBackwardKernel(cudaStream_t stream, const T* softmax_y, const T* dy, T* dx,
                                   const MASK* mask, const bool* dropout_mask,
                                   const int64_t elem_cnt, const int64_t rows, const int64_t cols,
                                   const float fill, const float scale, const float dropout_scale,
                                   const int64_t* input_dims, const int64_t* mask_dims) {
  DropoutLoad<T, ComputeType> load_dy(dy, dropout_mask, cols, dropout_scale);
  NdIndexOffsetHelper<int32_t, num_dims> input_index_helper(input_dims, num_dims);
  NdIndexOffsetHelper<int32_t, num_dims> mask_index_helper(mask_dims, num_dims);
  fused_scale_mask_softmax::BroadcastMaskSoftmaxParams<num_dims, int32_t> params;
  params.src_index_helper = input_index_helper;
  params.mask_index_helper = mask_index_helper;
  params.mask_dims = mask_dims;
  params.row_size = cols;
  params.fill = fill;
  params.scale = scale;
  cuda::softmax::DirectLoad<T, ComputeType> load_softmax_y(softmax_y, cols);
  fused_scale_mask_softmax::BroadcastScaleMaskStore<ComputeType, T, MASK, num_dims, int32_t> store(
      dx, mask, params);
  OF_CUDA_CHECK((cuda::softmax::DispatchSoftmaxGrad<decltype(load_softmax_y), decltype(load_dy),
                                                    decltype(store), ComputeType>(
      stream, load_softmax_y, load_dy, store, rows, cols)));
}

template<typename T, typename ComputeType, typename MASK>
void LaunchElementwiseBackwardKernel(cudaStream_t stream, const T* softmax_y, const T* dy, T* dx,
                                     const MASK* mask, const bool* dropout_mask, const int64_t rows,
                                     const int64_t cols, const float fill, const float scale,
                                     const float dropout_scale) {
  fused_scale_mask_softmax::ElementwiseMaskSoftmaxParams params;
  params.row_size = cols;
  params.fill = fill;
  params.scale = scale;
  cuda::softmax::DirectLoad<T, ComputeType> load_softmax_y(softmax_y, cols);
  DropoutLoad<T, ComputeType> load_dy(dy, dropout_mask, cols, dropout_scale);
  fused_scale_mask_softmax::ElementwiseScaleMaskStore<ComputeType, T, MASK> store(dx, mask, params);
  OF_CUDA_CHECK((cuda::softmax::DispatchSoftmaxGrad<decltype(load_softmax_y), decltype(load_dy),
                                                    decltype(store), ComputeType>(
      stream, load_softmax_y, load_dy, store, rows, cols)));
}

constexpr int32_t kMaxNumDims = 5;

template<typename T, typename MASK>
class FusedScaleMaskSoftmaxDropoutKernel final : public user_op::OpKernel {
 public:
  FusedScaleMaskSoftmaxDropoutKernel() = default;
  ~FusedScaleMaskSoftmaxDropoutKernel() override = default;

 private:
  using user_op::OpKernel::Compute;
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* x = ctx->Tensor4ArgNameAndIndex("x", 0);
    const user_op::Tensor* mask = ctx->Tensor4ArgNameAndIndex("mask", 0);
    const user_op::Tensor* dropout_mask = ctx->Tensor4ArgNameAndIndex("dropout_mask", 0);
    user_op::Tensor* y = ctx->Tensor4ArgNameAndIndex("y", 0);
    const float mask_fill_value = ctx->Attr<float>("mask_fill_value");
    const float scale_value = ctx->Attr<float>("scale_value");
    const float dropout_scale_value = ctx->Attr<float>("dropout_scale_value");
    user_op::Tensor* softmax_y = ctx->Tensor4ArgNameAndIndex("softmax_y", 0);
    const ShapeView& x_shape = x->shape_view();
    const ShapeView& mask_shape = mask->shape_view();
    CHECK_GE(x_shape.NumAxes(), 2);
    const int64_t elem_cnt = x_shape.elem_cnt();
    const int64_t cols = x_shape.At(x_shape.NumAxes() - 1);
    const int64_t rows = x_shape.Count(0, x_shape.NumAxes() - 1);
    const size_t num_input_dims = x_shape.NumAxes();
    const int64_t* input_dims = x_shape.ptr();
    const size_t num_mask_dims = mask_shape.NumAxes();
    const int64_t* mask_dims = mask_shape.ptr();
    using ComputeType = typename cuda::softmax::DefaultComputeType<T>::type;

    size_t simplified_num_dims = 0;
    int64_t simplified_input_dims[kMaxNumDims];
    int64_t simplified_mask_dims[kMaxNumDims];
    fused_scale_mask_softmax::SimplifyBroadcastDims(num_input_dims, input_dims, num_mask_dims,
                                                    mask_dims, &simplified_num_dims,
                                                    simplified_input_dims, simplified_mask_dims);
    if (simplified_num_dims == 1) {
      LaunchElementwiseForwardKernel<T, ComputeType, MASK>(
          ctx->stream()->As<ep::CudaStream>()->cuda_stream(), x->dptr<T>(), y->mut_dptr<T>(),
          softmax_y->mut_dptr<T>(), mask->dptr<MASK>(), dropout_mask->dptr<bool>(), rows, cols,
          mask_fill_value, scale_value, dropout_scale_value);
    }

#define DEFINE_ONE_ELIF(dims)                                                                     \
  else if (simplified_num_dims == dims) {                                                         \
    LaunchBroadcastForwardKernel<T, ComputeType, MASK, dims>(                                     \
        ctx->stream()->As<ep::CudaStream>()->cuda_stream(), x->dptr<T>(), y->mut_dptr<T>(),       \
        softmax_y->mut_dptr<T>(), mask->dptr<MASK>(), dropout_mask->dptr<bool>(), elem_cnt, rows, \
        cols, mask_fill_value, scale_value, dropout_scale_value, simplified_input_dims,           \
        simplified_mask_dims);                                                                    \
  }
    DEFINE_ONE_ELIF(2)
    DEFINE_ONE_ELIF(3)
    DEFINE_ONE_ELIF(4)
#undef DEFINE_ONE_ELIF
    else {
      UNIMPLEMENTED();
    }
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

template<typename T, typename MASK>
class FusedScaleMaskSoftmaxDropoutGradKernel final : public user_op::OpKernel {
 public:
  FusedScaleMaskSoftmaxDropoutGradKernel() = default;
  ~FusedScaleMaskSoftmaxDropoutGradKernel() override = default;

 private:
  using user_op::OpKernel::Compute;
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* softmax_y = ctx->Tensor4ArgNameAndIndex("softmax_y", 0);
    const user_op::Tensor* dy = ctx->Tensor4ArgNameAndIndex("dy", 0);
    const user_op::Tensor* mask = ctx->Tensor4ArgNameAndIndex("mask", 0);
    const user_op::Tensor* dropout_mask = ctx->Tensor4ArgNameAndIndex("dropout_mask", 0);
    user_op::Tensor* dx = ctx->Tensor4ArgNameAndIndex("dx", 0);
    const float mask_fill_value = static_cast<float>(0.0);
    const float scale_value = ctx->Attr<float>("scale_value");
    const float dropout_scale_value = ctx->Attr<float>("dropout_scale_value");
    const ShapeView& dy_shape = dy->shape_view();
    const int64_t elem_cnt = dy_shape.elem_cnt();
    const ShapeView& mask_shape = mask->shape_view();
    CHECK_GE(dy_shape.NumAxes(), 2);
    const int64_t cols = dy_shape.At(dy_shape.NumAxes() - 1);
    const int64_t rows = dy_shape.Count(0, dy_shape.NumAxes() - 1);
    const int64_t* input_dims = dy_shape.ptr();
    const size_t num_input_dims = dy_shape.NumAxes();
    const int64_t* mask_dims = mask_shape.ptr();
    const size_t num_mask_dims = mask_shape.NumAxes();

    using ComputeType = typename cuda::softmax::DefaultComputeType<T>::type;
    cuda::softmax::DirectLoad<T, ComputeType> load_softmax_y(softmax_y->dptr<T>(), cols);

    size_t simplified_num_dims = 0;
    int64_t simplified_input_dims[kMaxNumDims];
    int64_t simplified_mask_dims[kMaxNumDims];
    fused_scale_mask_softmax::SimplifyBroadcastDims(num_input_dims, input_dims, num_mask_dims,
                                                    mask_dims, &simplified_num_dims,
                                                    simplified_input_dims, simplified_mask_dims);
    if (simplified_num_dims == 1) {
      LaunchElementwiseBackwardKernel<T, ComputeType, MASK>(
          ctx->stream()->As<ep::CudaStream>()->cuda_stream(), softmax_y->dptr<T>(), dy->dptr<T>(),
          dx->mut_dptr<T>(), mask->dptr<MASK>(), dropout_mask->dptr<bool>(), rows, cols,
          mask_fill_value, scale_value, dropout_scale_value);
    }
#define DEFINE_ONE_ELIF(dims)                                                                    \
  else if (simplified_num_dims == dims) {                                                        \
    LaunchBroadcastBackwardKernel<T, ComputeType, MASK, dims>(                                   \
        ctx->stream()->As<ep::CudaStream>()->cuda_stream(), softmax_y->dptr<T>(), dy->dptr<T>(), \
        dx->mut_dptr<T>(), mask->dptr<MASK>(), dropout_mask->dptr<bool>(), elem_cnt, rows, cols, \
        static_cast<float>(0.0), ctx->Attr<float>("scale_value"),                                \
        ctx->Attr<float>("dropout_scale_value"), simplified_input_dims, simplified_mask_dims);   \
  }
    DEFINE_ONE_ELIF(2)
    DEFINE_ONE_ELIF(3)
    DEFINE_ONE_ELIF(4)
#undef DEFINE_ONE_ELIF
    else {
      UNIMPLEMENTED();
    }
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

}  // namespace

#define REGISTER_FUSED_SCALE_MASK_SOFTMAX_DROPOUT_CUDA_KERNEL(dtype, mask_dtype)      \
  REGISTER_USER_KERNEL("fused_scale_mask_softmax_dropout")                            \
      .SetCreateFn<FusedScaleMaskSoftmaxDropoutKernel<dtype, mask_dtype>>()           \
      .SetIsMatchedHob((user_op::HobDeviceType() == DeviceType::kCUDA)                \
                       && (user_op::HobDataType("x", 0) == GetDataType<dtype>::value) \
                       && (user_op::HobDataType("mask", 0) == GetDataType<mask_dtype>::value));

REGISTER_FUSED_SCALE_MASK_SOFTMAX_DROPOUT_CUDA_KERNEL(half, bool)
REGISTER_FUSED_SCALE_MASK_SOFTMAX_DROPOUT_CUDA_KERNEL(float, bool)
#undef REGISTER_FUSED_SCALE_MASK_SOFTMAX_DROPOUT_CUDA_KERNEL

#define REGISTER_FUSED_SCALE_MASK_SOFTMAX_DROPOUT_GRAD_KERNEL(dtype, mask_dtype)       \
  REGISTER_USER_KERNEL("fused_scale_mask_softmax_dropout_grad")                        \
      .SetCreateFn<FusedScaleMaskSoftmaxDropoutGradKernel<dtype, mask_dtype>>()        \
      .SetIsMatchedHob((user_op::HobDeviceType() == DeviceType::kCUDA)                 \
                       && (user_op::HobDataType("dx", 0) == GetDataType<dtype>::value) \
                       && (user_op::HobDataType("mask", 0) == GetDataType<mask_dtype>::value));

REGISTER_FUSED_SCALE_MASK_SOFTMAX_DROPOUT_GRAD_KERNEL(half, bool)
REGISTER_FUSED_SCALE_MASK_SOFTMAX_DROPOUT_GRAD_KERNEL(float, bool)
#undef REGISTER_FUSED_SCALE_MASK_SOFTMAX_DROPOUT_GRAD_KERNEL

}  // namespace oneflow
