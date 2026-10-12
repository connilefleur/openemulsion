#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Configure and build the OpenEmulsion OFX bundle on Linux.
# Usage: tools/build_ofx.sh [--resolve-openfx-root DIR] [--generator NAME] [--build-dir DIR] [-- extra cmake args]

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${repo_root}/build"
resolve_openfx_root=""
generator=""
extra_args=()

usage() {
    sed -n '4,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resolve-openfx-root) resolve_openfx_root="$2"; shift 2 ;;
        --generator) generator="$2"; shift 2 ;;
        --build-dir) build_dir="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; extra_args+=("$@"); break ;;
        *) extra_args+=("$1"); shift ;;
    esac
done

if [[ -z "${generator}" ]]; then
    if command -v ninja >/dev/null 2>&1; then
        generator="Ninja"
    else
        generator="Unix Makefiles"
    fi
fi

cmake_args=(-S "${repo_root}/ofx" -B "${build_dir}" -G "${generator}" -DCMAKE_BUILD_TYPE=Release)
if [[ -n "${resolve_openfx_root}" ]]; then
    cmake_args+=("-DRESOLVE_OPENFX_ROOT=${resolve_openfx_root}")
fi
cmake_args+=("${extra_args[@]}")

cmake "${cmake_args[@]}" || { echo "CMake configuration failed." >&2; exit 1; }
cmake --build "${build_dir}" --config Release -j || { echo "Plugin build failed." >&2; exit 1; }

echo "Built bundle:"
echo "${repo_root}/dist/OpenEmulsion.ofx.bundle"
