{ pkgs, pkgsCross }:
let
  riscvTestsSrc = pkgs.fetchFromGitHub {
    owner = "riscv-software-src";
    repo = "riscv-tests";
    rev = "b5ba87097c42aa41c56657e0ae049c2996e8d8d8";
    fetchSubmodules = true;
    hash = "sha256-gcoHRFDznlISVJU/IveZc1m59HUytc39Pf+obIKY0hQ=";
  };

  libprintf = import ./libprintf.nix {
    stdenv = pkgsCross.stdenv;
    fetchFromGitHub = pkgsCross.fetchFromGitHub;
  };
in rec {
  spike-mod = pkgs.spike.overrideAttrs (old: {
    src = pkgs.fetchFromGitHub {
      owner = "riscv";
      repo = "riscv-isa-sim";
      rev = "3e58f5ef626fa76dd6675f1f78c6cd8470e18727";
      sha256 = "sha256-A37a3e+YNHFpu3xWtidF14yvBLNM764o7tH1BdCesOY=";
    };

    patches = [
        ./spike_getpriv.patch
        ./spike_csrr_debug.patch
    ];

    doCheck = false;
    doInstallCheck = false;
    installCheckPhase = null;
  });

  riscv-tests-orig = pkgsCross.stdenv.mkDerivation {
    name = "riscv-tests-orig";
    src = riscvTestsSrc;

    enableParallelBuilding = true;

    nativeBuildInputs = with pkgs; [
      autoconf
    ];

    preConfigurePhases = [ "postPatchPhase" ];

    postPatchPhase = ''
      for f in isa mt benchmarks
      do
          sed -i 's/-unknown-elf-/-none-elf-/' $f/Makefile
      done
    '';

    configurePhase = ''
      autoconf
      ./configure --prefix=$out
    '';
  };

  riscv-tests = riscv-tests-orig.overrideAttrs (old: {
    name = "riscv-tests";

    patches = [ ./riscv_failing_test.patch ];

    postPatchPhase = old.postPatchPhase + ''
      rm ./env/p/riscv_test.h
      cp ${./riscv_test.h} ./env/p/riscv_test.h
    '';
  });

  riscv-devshell = pkgsCross.mkShell {
    nativeBuildInputs = with pkgs; [
      spike-mod
      dtc
      autoconf
    ];

    buildInputs = [ libprintf ];
  };
}
