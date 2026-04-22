{ pkgs, pkgsCross, ... }:
pkgsCross.stdenv.mkDerivation {
  name = "linux";
  version = "6.18.5";
  src = pkgsCross.fetchzip {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.5.tar.xz";
    hash = "sha256-YgS+IVTzvxjlZpAO3wTtf0vfUrF0HPIenQYM3ill738=";
  };

  enableParallelBuilding = true;

  buildInputs = (with pkgs; [ ncurses ]);

  nativeBuildInputs = (with pkgs; [
    pkg-config
    autoconf
    dtc
    ncurses
    bc
    flex
    bison
    gcc
    binutils
  ]);

  configurePhase = ''
    cp ${./configs/linux_minimal.config} ./.config
  '';

  preBuild = ''
    makeFlagsArray+=(
        KCFLAGS="-fno-pic -fno-pie"
        KCPPFLAGS="-fno-pic -fno-pie"
        LDFLAGS_vmlinux=-no-pie
        ARCH=riscv
        CROSS_COMPILE=riscv64-unknown-linux-musl-
    )
  '';
  
  installPhase = ''
    mkdir -p $out
    cp ./arch/riscv/boot/Image $out/
    cp ./vmlinux $out/
    cp ./vmlinux.unstripped $out/
  '';

  dontFixup = true;
}
