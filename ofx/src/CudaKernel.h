// SPDX-License-Identifier: MPL-2.0

#pragma once

// CUDA counterpart of RunOpenEmulsionOpenCL. `stream` is the host's cudaStream_t
// (kOfxImageEffectPropCudaStream, may be null for the default stream); `input`
// and `output` are packed RGBA float device pointers. Work is only enqueued on
// the stream; the call never synchronizes the device or reads results back.
bool RunOpenEmulsionCuda(void* stream, int width, int height, double time, const float* settings, const float* input, float* output);
