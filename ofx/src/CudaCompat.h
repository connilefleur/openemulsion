// SPDX-License-Identifier: MPL-2.0

#ifndef OPENEMULSION_CUDA_COMPAT_H
#define OPENEMULSION_CUDA_COMPAT_H

// The shared math headers compile as C++, OpenCL C, and CUDA. OE_FN marks their
// functions as host/device code under nvcc and is empty elsewhere. OpenCL never
// includes this file; the math headers define an empty OE_FN on that path.
#ifndef OE_FN
#ifdef __CUDACC__
#define OE_FN __host__ __device__
#else
#define OE_FN
#endif
#endif

#ifdef __CUDACC__
// OpenCL C builtins used by the kernel source, with OpenCL semantics. The
// shared math headers use only std:: math, so only the kernels need these.
// Build CUDA with -fmad=false to match the headers' FP_CONTRACT OFF.
#include <cuda_runtime.h>

static inline __device__ int oe_clamp(int v, int lo, int hi) { return min(max(v, lo), hi); }
static inline __device__ float oe_clamp(float v, float lo, float hi) { return fminf(fmaxf(v, lo), hi); }
static inline __device__ float2 oe_mix(float2 a, float2 b, float t)
{
    return make_float2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
}
static inline __device__ float4 oe_mix(float4 a, float4 b, float t)
{
    return make_float4(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t,
                       a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t);
}
static inline __device__ float2 operator+(float2 a, float2 b) { return make_float2(a.x + b.x, a.y + b.y); }
static inline __device__ float2 operator*(float2 a, float2 b) { return make_float2(a.x * b.x, a.y * b.y); }
static inline __device__ float2& operator+=(float2& a, float2 b) { a = a + b; return a; }
static inline __device__ float3 operator+(float3 a, float3 b) { return make_float3(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline __device__ float3& operator+=(float3& a, float3 b) { a = a + b; return a; }
static inline __device__ float4 operator+(float4 a, float4 b)
{
    return make_float4(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w);
}
static inline __device__ float4 operator*(float4 a, float b) { return make_float4(a.x * b, a.y * b, a.z * b, a.w * b); }
static inline __device__ float4 operator/(float4 a, float b) { return make_float4(a.x / b, a.y / b, a.z / b, a.w / b); }
static inline __device__ float4& operator+=(float4& a, float4 b) { a = a + b; return a; }
static inline __device__ float3 oe_fmax(float3 a, float b) { return make_float3(fmaxf(a.x, b), fmaxf(a.y, b), fmaxf(a.z, b)); }
// OpenCL all(a == b) on float3.
static inline __device__ bool oe_all_equal(float3 a, float3 b) { return a.x == b.x && a.y == b.y && a.z == b.z; }
static inline __device__ int oe_global_x() { return blockIdx.x * blockDim.x + threadIdx.x; }
static inline __device__ int oe_global_y() { return blockIdx.y * blockDim.y + threadIdx.y; }
#endif

#endif
