#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Install the built OpenEmulsion OFX bundle on Linux.
# Usage: tools/install_ofx.sh [--user [DIR]]
#   default  copy to /usr/OFX/Plugins (uses sudo)
#   --user   copy to DIR (default: <repo>/ofx-plugins) and print the OFX_PLUGIN_PATH to set

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source="${repo_root}/dist/OpenEmulsion.ofx.bundle"
target_root="/usr/OFX/Plugins"
user_install=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            user_install=1
            target_root="${repo_root}/ofx-plugins"
            if [[ $# -gt 1 && "$2" != -* ]]; then
                target_root="$2"
                shift
            fi
            shift ;;
        -h|--help) sed -n '4,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if pgrep -x resolve >/dev/null 2>&1; then
    echo "Close DaVinci Resolve before replacing the plugin." >&2
    exit 1
fi

if [[ ! -f "${source}/Contents/Linux-x86-64/OpenEmulsion.ofx" ]]; then
    echo "Cannot find built bundle at ${source}. Run tools/build_ofx.sh first." >&2
    exit 1
fi

target="${target_root%/}/OpenEmulsion.ofx.bundle"

if [[ ${user_install} -eq 1 ]]; then
    run=()
else
    run=(sudo)
fi

"${run[@]}" mkdir -p "${target_root}"
"${run[@]}" rm -rf "${target}"
"${run[@]}" cp -r "${source}" "${target_root}/"

echo "Installed ${target}"
if [[ ${user_install} -eq 1 ]]; then
    case ":${OFX_PLUGIN_PATH:-}:" in
        *":${target_root}:"*) echo "OFX_PLUGIN_PATH already includes ${target_root}" ;;
        *) echo "Add ${target_root} to OFX_PLUGIN_PATH before starting Resolve, e.g.:"
           echo "  export OFX_PLUGIN_PATH=\"${target_root}\${OFX_PLUGIN_PATH:+:\$OFX_PLUGIN_PATH}\"" ;;
    esac
fi
echo "Restart Resolve and look for OpenFX > OpenEmulsion > OpenEmulsion."
