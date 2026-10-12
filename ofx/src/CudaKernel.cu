// SPDX-License-Identifier: MPL-2.0

// CUDA port of the OpenCL kernels in OpenCLKernel.cpp. Kernels, pass order,
// buffer reuse, and parameter preparation mirror RunOpenEmulsionOpenCL one to
// one; the shared math headers compile here as host/device code (CudaCompat.h).

#include <cuda_runtime.h>

#include <map>
#include <memory>
#include <mutex>
#include <stdio.h>
#include <utility>

#include "CudaCompat.h"
#include "CudaKernel.h"
#include "HalationBlur.h"
#include "BloomBlur.h"
#include "HalationConfig.h"
#include "GrainConfig.h"
#include "ColorSpaceConfig.h"
#include "FilmResponseConfig.h"

static __device__ float lum(float3 c) { return c.x * 0.2126f + c.y * 0.7152f + c.z * 0.0722f; }

static __device__ float3 read_rgb(const float* input, int width, int height, int x, int y)
{
    x = oe_clamp(x, 0, width - 1);
    y = oe_clamp(y, 0, height - 1);
    int idx = ((y * width) + x) * 4;
    return make_float3(input[idx], input[idx + 1], input[idx + 2]);
}

static __device__ float highlight_key(float3 c, HalationParameters p)
{
    return halation_key(c.x, c.y, c.z, p);
}

static __device__ float3 to_work(float3 v, ColorParameters p)
{
    ColorRgb rgb = {v.x, v.y, v.z};
    rgb = color_to_work(rgb, p);
    return make_float3(rgb.r, rgb.g, rgb.b);
}

static __device__ float3 from_work(float3 v, ColorParameters p)
{
    ColorRgb rgb = {v.x, v.y, v.z};
    rgb = color_from_work(rgb, p);
    return make_float3(rgb.r, rgb.g, rgb.b);
}

__global__ void ExtractHighlights(int width, int height, int step, ColorParameters color, HalationParameters halo,
                                  const float* input, float2* output)
{
    int x = oe_global_x(), y = oe_global_y();
    int bw = (width + step - 1) / step, bh = (height + step - 1) / step;
    if (x >= bw || y >= bh) return;
    float sum = 0.0f;
    int count = 0;
    for (int dy = 0; dy < step && step * y + dy < height; ++dy) {
        for (int dx = 0; dx < step && step * x + dx < width; ++dx) {
            sum += highlight_key(to_work(read_rgb(input, width, height, step * x + dx, step * y + dy), color), halo);
            ++count;
        }
    }
    const float value = sum / count;
    output[y * bw + x] = make_float2(value, value);
}

__global__ void BlurHighlights(int width, int height, int radius, int horizontal,
                               const float2* weights, const float2* input, float2* output)
{
    int x = oe_global_x(), y = oe_global_y();
    if (x >= width || y >= height) return;
    float2 sum = make_float2(0.0f, 0.0f);
    for (int i = -radius; i <= radius; ++i) {
        int sx = horizontal ? oe_clamp(x + i, 0, width - 1) : x;
        int sy = horizontal ? y : oe_clamp(y + i, 0, height - 1);
        sum += input[sy * width + sx] * weights[i + radius];
    }
    output[y * width + x] = sum;
}

static __device__ float2 sample_blur(const float2* image, int width, int height, int x, int y, int step)
{
    float fx = oe_clamp(((float)x - (step - 1) * 0.5f) / step, 0.0f, (float)(width - 1));
    float fy = oe_clamp(((float)y - (step - 1) * 0.5f) / step, 0.0f, (float)(height - 1));
    int x0 = (int)fx, y0 = (int)fy;
    int x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1);
    float2 top = oe_mix(image[y0 * width + x0], image[y0 * width + x1], fx - x0);
    float2 bottom = oe_mix(image[y1 * width + x0], image[y1 * width + x1], fx - x0);
    return oe_mix(top, bottom, fy - y0);
}

__global__ void ExtractBloom(int width, int height, int step, ColorParameters color, BloomParameters parameters,
                             const float* input, float4* output)
{
    int x = oe_global_x(), y = oe_global_y();
    int bw = (width + step - 1) / step, bh = (height + step - 1) / step;
    if (x >= bw || y >= bh) return;
    float4 sum = make_float4(0.0f, 0.0f, 0.0f, 0.0f); int count = 0;
    for (int dy = 0; dy < step && y * step + dy < height; ++dy)
        for (int dx = 0; dx < step && x * step + dx < width; ++dx) {
            float3 rgb = read_rgb(input,width,height,x*step+dx,y*step+dy);
            ColorRgb c = bloom_extract(ColorRgb{rgb.x,rgb.y,rgb.z},color,parameters);
            sum += make_float4(c.r,c.g,c.b,0.0f); ++count;
        }
    output[y * bw + x] = sum / (float)count;
}

__global__ void BlurBloom(int width, int height, int radius, int horizontal,
                          const float* weights, const float4* input, float4* output)
{
    int x = oe_global_x(), y = oe_global_y();
    if (x >= width || y >= height) return;
    float4 sum = make_float4(0.0f, 0.0f, 0.0f, 0.0f);
    for (int i = -radius; i <= radius; ++i) {
        int sx = horizontal ? oe_clamp(x+i,0,width-1) : x;
        int sy = horizontal ? y : oe_clamp(y+i,0,height-1);
        sum += input[sy*width+sx] * weights[i+radius];
    }
    output[y*width+x] = sum;
}

static __device__ float4 sample_bloom(const float4* image, int width, int height, int x, int y, int step)
{
    float fx = oe_clamp(((float)x - (step-1)*0.5f)/step,0.0f,(float)(width-1));
    float fy = oe_clamp(((float)y - (step-1)*0.5f)/step,0.0f,(float)(height-1));
    int x0 = (int)fx, y0 = (int)fy;
    int x1 = min(x0+1,width-1), y1 = min(y0+1,height-1);
    float4 top = oe_mix(image[y0*width+x0],image[y0*width+x1],fx-x0);
    float4 bottom = oe_mix(image[y1*width+x0],image[y1*width+x1],fx-x0);
    return oe_mix(top,bottom,fy-y0);
}

__global__ void OpenEmulsionKernel(
    int width,
    int height,
    int modules,
    int mode,
    float gainR,
    float gainG,
    float gainB,
    float halation,
    float aura,
    float grain,
    GrainParameters grainParameters,
    ColorParameters color,
    FilmResponseParameters response,
    HalationParameters haloParameters,
    BloomParameters bloomParameters,
    int bloomStep,
    int step,
    int identity,
    const float* input,
    float* output,
    const float2* blurred,
    const float4* bloomed)
{
    int x = oe_global_x();
    int y = oe_global_y();
    if (x >= width || y >= height) return;

    int idx = ((y * width) + x) * 4;
    float3 original = make_float3(input[idx], input[idx + 1], input[idx + 2]);
    float alpha = input[idx + 3];
    if (identity) {
        output[idx] = original.x; output[idx + 1] = original.y; output[idx + 2] = original.z; output[idx + 3] = alpha;
        return;
    }
    float3 work = to_work(original, color);
    float3 c = work;
    ColorRgb selectionSource = {work.x,work.y,work.z};

    {
        ColorRgb rgb = {c.x, c.y, c.z};
        if (modules & 1) {
            ColorRgb gain = {gainR, gainG, gainB};
            rgb = color_balance(rgb, gain);
            selectionSource = rgb;
        }
        rgb = color_render_work(rgb, color);
        if (modules & 1) rgb = response_negative_stage(rgb, response);
        c = make_float3(rgb.r, rgb.g, rgb.b);
    }
    if (modules & 32) {
        ColorRgb rgb = response_development(ColorRgb{c.x, c.y, c.z}, response);
        c = make_float3(rgb.r, rgb.g, rgb.b);
    }
    if (grainParameters.prePrint && grain > 0.0f) {
        GrainVector delta = grain_delta(x, y, lum(c), grainParameters);
        c += make_float3(delta.r, delta.g, delta.b);
    }
    if (modules & 2) {
        ColorRgb rgb = {c.x, c.y, c.z};
        rgb = response_print(rgb, response);
        c = make_float3(rgb.r, rgb.g, rgb.b);
    }

    if (halation > 0.0f || aura > 0.0f) {
        float2 halo = sample_blur(blurred, (width + step - 1) / step, (height + step - 1) / step, x, y, step);
        float center = highlight_key(work, haloParameters);
        float h = halation_signal(halo.x, halo.y, center, halation, aura);
        if (mode == 5) {
            h = oe_clamp(h * 2.0f, 0.0f, 1.0f);
            c = make_float3(h, h * 0.55f, h * 0.10f);
        } else {
            c += make_float3(h * haloParameters.red, h * haloParameters.green, h * haloParameters.blue);
        }
    } else if (mode == 5) {
        c = make_float3(0.0f, 0.0f, 0.0f);
    }

    if (bloomParameters.amount > 0.0f || mode == 6) {
        float4 glow = bloomParameters.amount > 0.0f ?
            sample_bloom(bloomed, (width + bloomStep - 1) / bloomStep, (height + bloomStep - 1) / bloomStep, x, y, bloomStep) :
            make_float4(0.0f, 0.0f, 0.0f, 0.0f);
        ColorRgb rgb = bloom_composite(ColorRgb{c.x,c.y,c.z}, ColorRgb{glow.x,glow.y,glow.z}, bloomParameters, mode == 6);
        c = make_float3(rgb.r,rgb.g,rgb.b);
    }
    if ((modules & 16) && grain > 0.0f && !grainParameters.prePrint) {
        GrainVector delta = grain_delta(x, y, lum(c), grainParameters);
        c += make_float3(delta.r, delta.g, delta.b);
    }

    ColorRgb finished = response_finish(ColorRgb{c.x, c.y, c.z}, modules, response);
    if (modules & 128) finished = response_selective(finished, selectionSource, response);
    c = make_float3(finished.r, finished.g, finished.b);
    if (response_clamps_negative(modules, response)) c = oe_fmax(c, 0.0f);
    if (mode != 5 && mode != 6 && !((modules & 128) && response.selectiveView))
        c = !(modules & 163) && oe_all_equal(c, work) ? original : from_work(c, color);
    output[idx] = c.x;
    output[idx + 1] = c.y;
    output[idx + 2] = c.z;
    output[idx + 3] = alpha;
}

static bool check(cudaError_t error, const char* msg)
{
    if (error != cudaSuccess) {
        fprintf(stderr, "%s [%d: %s]\n", msg, static_cast<int>(error), cudaGetErrorString(error));
        return false;
    }
    return true;
}

static dim3 gridFor(int width, int height, dim3 block)
{
    return dim3((width + block.x - 1) / block.x, (height + block.y - 1) / block.y, 1);
}

// Scratch buffers cached per (device, stream), like the OpenCL path caches per queue.
// Every use is ordered on the owning stream, so reuse needs no host synchronization.
struct CudaResources {
    cudaStream_t stream;
    bool asyncAlloc = false;
    float2* highlights = nullptr;
    float2* temporary = nullptr;
    size_t capacity = 0;
    float4* bloomHighlights = nullptr;
    float4* bloomTemporary = nullptr;
    size_t bloomCapacity = 0;
    void* haloWeights = nullptr;
    size_t haloWeightsCapacity = 0;
    void* bloomWeights = nullptr;
    size_t bloomWeightsCapacity = 0;

    CudaResources(int device, cudaStream_t s) : stream(s)
    {
        int pools = 0;
        asyncAlloc = cudaDeviceGetAttribute(&pools, cudaDevAttrMemoryPoolsSupported, device) == cudaSuccess && pools != 0;
    }

    bool allocate(void** ptr, size_t bytes, const char* msg)
    {
        return check(asyncAlloc ? cudaMallocAsync(ptr, bytes, stream) : cudaMalloc(ptr, bytes), msg);
    }

    void release(void* ptr)
    {
        if (!ptr) return;
        if (asyncAlloc) cudaFreeAsync(ptr, stream);
        else cudaFree(ptr);
    }

    // Grows a pair of same-sized buffers; old contents are not preserved.
    template<class T>
    bool reserve(T*& a, T*& b, size_t& current, size_t bytes, const char* msgA, const char* msgB)
    {
        if (current >= bytes) return true;
        void* na = nullptr;
        void* nb = nullptr;
        if (!allocate(&na, bytes, msgA)) return false;
        if (!allocate(&nb, bytes, msgB)) { release(na); return false; }
        release(a);
        release(b);
        a = static_cast<T*>(na);
        b = static_cast<T*>(nb);
        current = bytes;
        return true;
    }

    bool upload(void*& buffer, size_t& current, const void* data, size_t bytes, const char* msg)
    {
        if (current < bytes) {
            void* next = nullptr;
            if (!allocate(&next, bytes, msg)) return false;
            release(buffer);
            buffer = next;
            current = bytes;
        }
        return check(cudaMemcpyAsync(buffer, data, bytes, cudaMemcpyHostToDevice, stream), msg);
    }
};

static bool launched(const char* msg)
{
    return check(cudaGetLastError(), msg);
}

bool RunOpenEmulsionCuda(void* cudaStream, int width, int height, double time, const float* settings, const float* input, float* output)
{
    if (!input || !output || width <= 0 || height <= 0) return false;

    cudaStream_t stream = static_cast<cudaStream_t>(cudaStream);
    static std::mutex mutex;
    using Key = std::pair<int, cudaStream_t>;
    // Intentionally never destroyed: freeing device memory during static
    // destruction can run after the host has torn down its CUDA context.
    static auto* resources = new std::map<Key, std::unique_ptr<CudaResources>>();

    std::lock_guard<std::mutex> lock(mutex);

    int device = 0;
    if (!check(cudaGetDevice(&device), "Unable to get CUDA device")) return false;
    const Key key(device, stream);
    if (resources->find(key) == resources->end())
        resources->emplace(key, std::make_unique<CudaResources>(device, stream));
    CudaResources& state = *resources->at(key);

    int mode = static_cast<int>(settings[0] + 0.5f);
    const int modules = film::modulesForSettings(settings);
    const float halation = (modules & film::Halation) ? settings[13] : 0.0f;
    const float aura = (modules & film::Aura) ? settings[15] : 0.0f;
    const GrainParameters grainParameters = grain::prepare(settings, height, time);
    const ColorParameters colorParameters = color::prepare(settings);
    const FilmResponseParameters responseParameters = response::prepare(settings);
    static_assert(sizeof(FilmResponseParameters) == 236, "CUDA response structure layout mismatch");
    const auto haloConfig = halation::prepare(settings, height);
    const int step = haloConfig.downsample;
    static_assert(sizeof(HalationParameters) == 20, "CUDA halation structure layout mismatch");
    const auto bloomConfig = bloom::prepare(settings, height);
    static_assert(sizeof(BloomParameters) == 20, "CUDA bloom structure layout mismatch");
    static_assert(sizeof(bloom::Pixel) == sizeof(float4), "CUDA bloom float4 layout mismatch");
    const int identity = film::isIdentity(mode, modules, halation, aura, settings[16], bloomConfig.parameters.amount,
                                          responseParameters.selectiveAmount, responseParameters.selectiveView);
    static_assert(sizeof(ColorParameters) == 128, "CUDA color structure layout mismatch");
    static_assert(sizeof(GrainParameters) == 64, "CUDA grain structure layout mismatch");

    const dim3 block(32, 8, 1);
    const float2* blurMem = reinterpret_cast<const float2*>(input);
    if (halation > 0.0f || aura > 0.0f) {
        const int bw = (width + step - 1) / step, bh = (height + step - 1) / step;
        const size_t bytes = static_cast<size_t>(bw) * bh * sizeof(halation::Pair);
        if (!state.reserve(state.highlights, state.temporary, state.capacity, bytes,
                           "Unable to allocate highlight buffer", "Unable to allocate blur buffer")) return false;
        const halation::Filter filter(halation, settings[14], aura, haloConfig.auraRadius, haloConfig.radiusScale);
        static_assert(sizeof(halation::Pair) == sizeof(float2), "CUDA float2 layout mismatch");
        if (!state.upload(state.haloWeights, state.haloWeightsCapacity, filter.weights.data(),
                          filter.weights.size() * sizeof(halation::Pair), "Unable to upload halation weights")) return false;
        const dim3 grid = gridFor(bw, bh, block);
        ExtractHighlights<<<grid, block, 0, stream>>>(width, height, step, colorParameters, haloConfig.key, input, state.highlights);
        if (!launched("Unable to launch highlight kernel")) return false;
        for (int horizontal = 1; horizontal >= 0; --horizontal) {
            const float2* src = horizontal ? state.highlights : state.temporary;
            float2* dst = horizontal ? state.temporary : state.highlights;
            BlurHighlights<<<grid, block, 0, stream>>>(bw, bh, filter.radius, horizontal,
                                                       static_cast<const float2*>(state.haloWeights), src, dst);
            if (!launched("Unable to launch blur kernel")) return false;
        }
        blurMem = state.highlights;
    }

    const float4* bloomMem = reinterpret_cast<const float4*>(input);
    if (bloomConfig.parameters.amount > 0.0f) {
        const int bloomStep = bloomConfig.downsample;
        const int bw = (width + bloomStep - 1) / bloomStep, bh = (height + bloomStep - 1) / bloomStep;
        const size_t bytes = static_cast<size_t>(bw) * bh * sizeof(bloom::Pixel);
        if (!state.reserve(state.bloomHighlights, state.bloomTemporary, state.bloomCapacity, bytes,
                           "Unable to allocate bloom buffer", "Unable to allocate bloom temporary")) return false;
        const bloom::Filter filter(bloomConfig.sigma);
        if (!state.upload(state.bloomWeights, state.bloomWeightsCapacity, filter.weights.data(),
                          filter.weights.size() * sizeof(float), "Unable to upload bloom weights")) return false;
        const dim3 grid = gridFor(bw, bh, block);
        ExtractBloom<<<grid, block, 0, stream>>>(width, height, bloomStep, colorParameters, bloomConfig.parameters,
                                                 input, state.bloomHighlights);
        if (!launched("Unable to launch bloom extraction kernel")) return false;
        for (int horizontal = 1; horizontal >= 0; --horizontal) {
            const float4* src = horizontal ? state.bloomHighlights : state.bloomTemporary;
            float4* dst = horizontal ? state.bloomTemporary : state.bloomHighlights;
            BlurBloom<<<grid, block, 0, stream>>>(bw, bh, filter.radius, horizontal,
                                                  static_cast<const float*>(state.bloomWeights), src, dst);
            if (!launched("Unable to launch bloom blur kernel")) return false;
        }
        bloomMem = state.bloomHighlights;
    }

    OpenEmulsionKernel<<<gridFor(width, height, block), block, 0, stream>>>(
        width, height, modules, mode, settings[4], settings[5], settings[6], halation, aura, settings[16],
        grainParameters, colorParameters, responseParameters, haloConfig.key, bloomConfig.parameters,
        bloomConfig.downsample, step, identity, input, output, blurMem, bloomMem);
    return launched("Unable to launch CUDA film kernel");
}
