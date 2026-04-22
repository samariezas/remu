{ pkgs, pkgsCross, ... }:
pkgsCross.stdenv.mkDerivation rec {
  name = "opensbi";
  version = "1.8.1";

  src = pkgsCross.fetchFromGitHub {
    owner = "riscv-software-src";
    repo = "opensbi";
    rev = "v${version}";
    hash = "sha256-nD22UZfH0rJECHMDwd9ATyLz44cFHqcFH7N6piK8hog=";
  };

  enableParallelBuilding = true;
  nativeBuildInputs = with pkgs; [
    dtc
    python3
  ];

  makeFlags = [
    "PLATFORM=generic"
    "PLATFORM_RISCV_ISA=rv64ima_zicsr_zifencei"
  ];

  patchPhase = ''
    patchShebangs --build ./scripts
  '';

  installPhase = ''
    mkdir -p $out
    cp -r build/platform/generic/firmware/* $out/
    echo $CROSS_COMPILE > $out/cross_comp_var
  '';

  dontFixup = true;
}
