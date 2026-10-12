# Task: port OpenEmulsion to Linux x64 with a CUDA backend

Fork of https://github.com/technomancer702/openemulsion (remote `upstream`). Work on branch `linux-cuda`.
Goal: `OpenEmulsion.ofx.bundle/Contents/Linux-x86-64/OpenEmulsion.ofx` that loads in DaVinci Resolve Studio 21.1
on this machine and renders on the GPU via CUDA, with OpenCL and the CPU renderer kept as fallbacks.
Keep the Windows build working; upstream wants to merge this eventually, so stay close to their style (see AGENTS.md, CONTRIBUTING.md).

## Machine facts (verified 2026-10-12)
- RHEL 9.8, GCC 11.5, CMake 3.31.8, clang available. No nvcc yet: install CUDA toolkit (`pkexec dnf install cuda-toolkit` from the NVIDIA repo, or the `.run` installer) matching driver 580.178.04 (CUDA 13.x works; 12.x is fine too).
- GPU: RTX 4070 Ti SUPER (sm_89). Resolve runs in CUDA GPU-processing mode by default, so OFX plugins receive CUDA buffers, not OpenCL ones. Without a CUDA path the plugin falls back to CPU.
- Resolve OpenFX SDK: `/opt/resolve/Developer/OpenFX` (OpenFX-1.4 headers + Support library). Reference examples there: `GainPlugin`, `TemporalBlurPlugin` show the Resolve CUDA/OpenCL/Metal buffer handshake (`kOfxImageEffectPropCudaRenderSupported`, `kOfxImageEffectPropCudaStream`, etc.). Read `GainPlugin/GainPlugin.cpp` + `CudaKernel.cu` first.
- OpenCL runtime: `/usr/lib64/libOpenCL.so.1` present; headers not installed (`dnf install opencl-headers ocl-icd-devel` if needed; the plugin loads OpenCL dynamically so headers are optional).
- Install target: `/usr/OFX/Plugins/` (root, use `pkexec`). ARRI bundles already live there as a layout reference.
- Resolve MCP is available to an agent in Claude Code (`resolve` server): `run_script`, `get_resolve_status`, `launch_resolve` — use it to verify the plugin appears and renders.

## Windows-only code to replace (everything else is portable C++17)
1. `ofx/src/OpenCLKernel.cpp` lines ~3, ~55, ~301-303: `LoadLibraryA("OpenCL.dll")` / `GetProcAddress` / `HMODULE`.
   → `dlopen("libOpenCL.so.1", RTLD_LAZY)` / `dlsym` / `void*` behind `#ifdef _WIN32`. Link `${CMAKE_DL_LIBS}`.
2. `ofx/src/UserPresetIO.h` (71 lines): Win32 `GetOpenFileNameW` / `GetSaveFileNameW` file dialog for user presets.
   → Linux: shell out to `kdialog --getopenfilename` / `--getsavefilename` (KDE here), fall back to `zenity --file-selection`.
   Keep the Windows branch under `#ifdef _WIN32`.
3. `ofx/CMakeLists.txt`:
   - remove the `if(NOT WIN32 ...) FATAL_ERROR` guard; add per-platform defaults for `RESOLVE_OPENFX_ROOT`
     (Linux: `/opt/resolve/Developer/OpenFX`).
   - `comdlg32` and `NOMINMAX` only on WIN32; add `Threads::Threads` and `${CMAKE_DL_LIBS}`.
   - bundle output dir: `Contents/Win64` on Windows, `Contents/Linux-x86-64` on Linux, `Contents/MacOS` on Apple.
   - `BUILD_TESTING` uses PowerShell for one test: skip that test when `pwsh` is absent instead of `REQUIRED`.
   - add `option(OPENEMULSION_CUDA ON)` → `enable_language(CUDA)`, `CMAKE_CUDA_ARCHITECTURES` default `89;86;75`, build `.cu` into the same shared lib.
   - Set `-fvisibility=hidden` and export only `OfxGetPlugin`/`OfxGetNumberOfPlugins` (see how Resolve's example plugins do it; a `.map`/version script or `__attribute__((visibility("default")))`).
4. `tools/*.ps1` are Windows-only build/package scripts; add `tools/build_ofx.sh` and `tools/install_ofx.sh` equivalents. Do not delete the ps1 files.

## CUDA backend design
- The GPU math already lives in shared headers (`GrainMath.h`, `ColorMath.h`, `FilmResponseMath.h`, `HalationMath.h`, `BloomMath.h`)
  that CMake splices into OpenCL kernel source strings via the `*OpenCL.h.in` templates. Those headers are written to compile as both
  C++ and OpenCL C. Make them compile as CUDA too: `__device__ __host__` qualifiers via a macro (e.g. `OE_FN`) that expands to nothing
  for C++/OpenCL, to `__host__ __device__ inline` for `__CUDACC__`. Check for OpenCL-only builtins (`fast_length`, `native_*`, `float4` swizzles like `.xyz`, `convert_*`, `mad`) and give them a tiny compat shim header.
- Port each kernel in `*OpenCL.h.in` to `.cu` files one to one (grain, color, film response, halation blur, bloom blur). Mirror the launch
  geometry and the work-buffer reuse described in `docs/BLOOM.md`, `docs/TEXTURE_CONTROLS.md`, and `OpenCLKernel.cpp`'s `RunOpenEmulsionOpenCL`.
- Add `RunOpenEmulsionCuda(...)` with the same signature as the OpenCL entry point; in `OpenEmulsion.cpp` `render()`: if the host
  supplies a CUDA stream/buffers → CUDA; else OpenCL; else CPU. Declare CUDA support in `describe()`.
- Use the host-provided `cudaStream_t` from `kOfxImageEffectPropCudaStream`; never `cudaDeviceSynchronize()` on the device, sync the stream only when required.
- Parity: the repo's tests check CPU vs OpenCL parity (`ofx/tests/HalationTests.cpp` etc.). Add a CPU vs CUDA parity check with the same tolerances.

## Verification
1. `cmake -S ofx -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j` → bundle in `build/`.
2. `ctest --test-dir build` (skip the PowerShell test).
3. `pkexec cp -r build/OpenEmulsion.ofx.bundle /usr/OFX/Plugins/`, restart Resolve, confirm the effect appears under OpenFX in the Color page.
4. Apply it on a clip at the timeline level, toggle modules, confirm GPU rendering (Resolve log `~/.local/share/DaVinciResolve/logs/ResolveDebug.txt` shows plugin load errors; playback FPS tells CPU vs GPU apart).
5. Verify a saved project reloads the plugin state.

## Intended use here
Timeline-level node chain: bloom/halation (linear) → ACES ODT → vignette → grain. OpenEmulsion is meant to sit in the grain/halation slots, so GPU speed at UHD matters.

## Deliverable
Working branch `linux-cuda` on the fork `connilefleur/openemulsion`, build + install scripts, README section "Build on Linux", and a short note of anything that differs from Windows behaviour. Open a PR against upstream only after the user has reviewed.
