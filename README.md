# remu

`remu` is a small RISC-V system emulator written in Zig. It implements enough of the RV64 machine to boot OpenSBI, load a Linux kernel, provide a small initramfs, and run guest programs. The project also contains experimental QPU instructions and helper programs used for testing them from Linux userspace.


## Repository layout

```text
.
├── build.zig              # Zig build description for the emulator
├── src/                   # emulator source code
├── image/                 # guest Linux image, initramfs and RISC-V userspace packages
├── libquantum-wrap/       # host-side wrapper library used by the emulator/QPU support
└── tests/                 # riscv-tests, Spike patches and custom trap tests
```

## Requirements

The normal development workflow uses Nix. Enable flakes and the `nix-command` interface in your Nix installation:

```sh
echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf
systemctl restart nix-daemon
```

The project also builds several large dependencies, including cross-compilers and target libraries for RISC-V. The first build can therefore take a long time if the dependencies are not already present in the Nix store.

## Importing the prepared build package

If you are not interested in using the pre-built package, feel free to skip this chapter entirely (everything will work, it just might take a few hours to build everything).

A prepared Nix store package is available so that the largest toolchain dependencies do not need to be built locally. Note that by default, Nix will reject the package with the error `cannot add path ... because it lacks a signature by a trusted key`. To fix this, allow non-signed packages (note that this is dangerous, as it allows importing untrusted code; proceed at your own risk):

```sh
echo "require-sigs = false" >> /etc/nix/nix.conf
systemctl restart nix-daemon
```

Download the package (~473MiB) and import it into the Nix store before running the emulator:

```sh
wget https://mif.vu.lt/~jope9155/remu/devshell.nar.gz
gunzip -c devshell.nar.gz | nix-store --import
```

After importing the package, running the project should only build the Linux image, OpenSBI, userspace and the emulator itself.

## Building and running

Start the emulator through the development shell:

```sh
nix develop -c ./start.sh --release
```

The `--release` argument builds the emulator in release mode before starting it. Without it, the painfully slow debug build will be launched. The script builds the required image artifacts and starts the emulator.

Usage of the already-built emulator:
```
./zig-out/bin/remu <OpenSBI fw_dynamic.bin path> <DTB path> <kernel path> <initrd path> [GDB socket path]
```

## The `image/` directory

The `image/` directory describes the guest system that is booted by the emulator. It is separate from the host emulator build: most files in this directory are cross-compiled for the RISC-V Linux guest, not for the host machine.

Important files and subdirectories:

- `image/default.nix` ties the guest image components together. It builds the RISC-V userspace packages, Linux, OpenSBI and the initramfs.
- `image/linux.nix`, `image/linux.patch` and `image/configs/` define the Linux kernel build and kernel configuration.
- `image/opensbi.nix` builds the OpenSBI firmware used as the first software stage.
- `image/initramfs.nix` creates the initramfs by collecting the selected derivations and packing them into a `newc` CPIO archive.
- `image/init` is the guest init script. It mounts `/proc`, `/dev` and `/sys`, enters `/samples`, and starts an interactive shell.
- `image/utils/` contains RISC-V guest utilities and QPU helper code. These are compiled into guest binaries/libraries and included in the initramfs.
- `image/samples/` contains small C programs copied into the guest as source files. Inside the guest, `build-all.sh` can compile them with `tcc`.

Use `image/` for files that should exist inside the emulated Linux system.

## Adding a guest-compiled C program

Programs placed in `image/samples/` are copied into `/samples` in the guest initramfs. For example, add a file:

```c
/* image/samples/example.c */
#include <stdio.h>

int main(void) {
    puts("hello from the RISC-V guest");
    return 0;
}
```

Then add it to `image/samples/build-all.sh`:

```sh
tcc example.c -o example
```

Rebuild the initramfs and run the emulator:

```sh
nix develop -c ./start.sh --release
```

Inside the guest shell:

```sh
./build-all.sh
./example
```

## Adding a host-compiled C program

Programs can be built on the host machine using cross-gcc by adding to the `image/utils` directory. First, create the source file:

```c
/* image/utils/hello-host.c */
#include <stdio.h>

int main(void) {
    printf("hello from the host system\n");
    return 0;
}
```

After that, stage the file using `git add image/utils`, as otherwise Nix will ignore the new file. Rebuild the initramfs and start the emulator:

```sh
nix develop -c ./start.sh --release
```

The new program will be available in the image:
```
/samples # ls /bin/hello-host
/bin/hello-host
/samples # hello-host
hello from the host system
/samples #
```
