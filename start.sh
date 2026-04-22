#!/usr/bin/env bash
set -euo pipefail
rm -f gdb.sock

USE_PERF=false
ZIG_OPTIMIZATION_LEVEL="Debug"
LAUNCH_GDB=false

for arg in "$@"; do
    case "$arg" in
        --perf)
            USE_PERF=true
        ;;
        --release)
            ZIG_OPTIMIZATION_LEVEL="ReleaseSafe"
        ;;
        --gdb)
            LAUNCH_GDB=true
        ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Supported args: --perf, --release" >&2
            exit 1
        ;;
    esac
done

IMAGE_BUILD_DIR="./image-build"
GDB_SOCKET_FILE="${IMAGE_BUILD_DIR}/gdb.sock"
OPENSBI_LOCATION="${IMAGE_BUILD_DIR}/opensbi"
DTB_FILE="${IMAGE_BUILD_DIR}/simple.dtb"
LINUX_LOCATION="${IMAGE_BUILD_DIR}/linux"

mkdir -p "${IMAGE_BUILD_DIR}"

if [[ -S "${GDB_SOCKET_FILE}" ]]; then
    rm -f "${GDB_SOCKET_FILE}" 
    echo "Removing gdb socket"
fi

if [[ ! -d "${OPENSBI_LOCATION}" ]]; then
    echo "Building opensbi"
    nix build ".#image-opensbi" -o "${OPENSBI_LOCATION}"
fi

if [[ ! -f "${DTB_FILE}" ]]; then
    echo "Building DTB"
    dtc ./simple.dts > "${DTB_FILE}"
fi

if [[ ! -d "${LINUX_LOCATION}" ]]; then
    echo "Building Linux"
    nix build ".#image-linux" -o "${LINUX_LOCATION}"
fi

set -x
zig build "-Doptimize=${ZIG_OPTIMIZATION_LEVEL}"

COMMAND=()

if $USE_PERF; then
    COMMAND+=(
        perf record
        --call-graph fp
        -D 3000-23000
    )
fi

COMMAND+=(
    zig-out/bin/bemu binary
    "${OPENSBI_LOCATION}/fw_dynamic.bin"
    "${DTB_FILE}"
    "${LINUX_LOCATION}/Image"
)

if $LAUNCH_GDB; then
    COMMAND+=("${GDB_SOCKET_FILE}")
fi

exec "${COMMAND[@]}"
