{ pkgs, pkgsCross }:
pkgs.stdenvNoCC.mkDerivation {
  name = "linux";
  version = "6.18.5";
  src = pkgs.fetchzip {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.5.tar.xz";
    hash = "sha256-YgS+IVTzvxjlZpAO3wTtf0vfUrF0HPIenQYM3ill738=";
  };

  enableParallelBuilding = true;

  nativeBuildInputs = (with pkgs; [
    pkg-config
    autoconf
    dtc
    ncurses
    bc
    flex
    bison
  ]) ++ (with pkgsCross; [
    gcc
    binutils
  ]);

  buildInputs = (with pkgs; [
    gcc
  ]);

  configurePhase = ''
    cp ${./configs/linux_minimal.config} ./.config
  '';

  makeFlags = [
    "ARCH=riscv"
    "CROSS_COMPILE=riscv64-unknown-linux-musl-"
  ];
  
  installPhase = ''
    cp ./arch/riscv/boot/Image $out
  '';

  dontFixup = false;
}
