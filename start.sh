#!/usr/bin/env bash
set -euo pipefail
rm -f gdb.sock

USE_PERF=false
ZIG_OPTIMIZATION_LEVEL="Debug"
USE_HOST_GDB=false
USE_REMOTE_GDB=false

for arg in "$@"; do
    case "$arg" in
        --perf)
            USE_PERF=true
        ;;
        --release)
            ZIG_OPTIMIZATION_LEVEL="ReleaseSafe"
        ;;
        --gdb-remote)
            USE_REMOTE_GDB=true
        ;;
        --gdb-host)
            USE_HOST_GDB=true
        ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Supported args: --perf, --release, --gdb-remote, --gdb-host" >&2
            exit 1
        ;;
    esac
done

if $USE_PERF && $USE_HOST_GDB; then
    echo "Using perf and host gdb? You sure?" >&2
    exit 1
fi

if $USE_PERF && $USE_REMOTE_GDB; then
    echo "Using perf and remote gdb? You sure?" >&2
    exit 1
fi

IMAGE_BUILD_DIR="./image-build"
GDB_SOCKET_FILE="${IMAGE_BUILD_DIR}/gdb.sock"
OPENSBI_LOCATION="${IMAGE_BUILD_DIR}/opensbi"
DTB_FILE="${IMAGE_BUILD_DIR}/simple.dtb"
LINUX_LOCATION="${IMAGE_BUILD_DIR}/linux"
INITRD_LOCATION="${IMAGE_BUILD_DIR}/initrd"

mkdir -p "${IMAGE_BUILD_DIR}"

if [[ -S "${GDB_SOCKET_FILE}" ]]; then
    rm -f "${GDB_SOCKET_FILE}" 
    echo "Removing gdb socket"
fi

if [[ ! -d "${OPENSBI_LOCATION}" ]]; then
    echo "Building opensbi"
    nix build ".#image-opensbi" -o "${OPENSBI_LOCATION}"
fi

if [[ ! -d "${LINUX_LOCATION}" ]]; then
    echo "Building Linux"
    nix build ".#image-linux" -o "${LINUX_LOCATION}"
fi

set -x
nix build ".#image-initramfs" -o "${INITRD_LOCATION}"
echo "Building DTB"
INITRD_SIZE=$(printf "%07x" "$(stat -c %s $(readlink ${INITRD_LOCATION}))")
sed "s/{INITRD_SIZE}/${INITRD_SIZE}/" ./simple.dts.template | dtc > "${DTB_FILE}"
zig build "-Doptimize=${ZIG_OPTIMIZATION_LEVEL}"

COMMAND=()

if $USE_PERF; then
    COMMAND+=(
        perf record
        --call-graph fp
        -D 3000-48000
    )
fi

COMMAND+=(
    zig-out/bin/remu binary
    "${OPENSBI_LOCATION}/fw_dynamic.bin"
    "${DTB_FILE}"
    "${LINUX_LOCATION}/Image"
    "${INITRD_LOCATION}"
)

if $USE_REMOTE_GDB; then
    COMMAND+=("${GDB_SOCKET_FILE}")
fi

if $USE_HOST_GDB; then
    exec gdb --args "${COMMAND[@]}"
else
    exec "${COMMAND[@]}"
fi
