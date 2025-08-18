{ pkgs, ... }:
let
  riscvPkgs = pkgs.pkgsCross.riscv64-embedded;
  riscvTestsSrc = pkgs.fetchFromGitHub {
    owner = "riscv-software-src";
    repo = "riscv-tests";
    rev = "b5ba87097c42aa41c56657e0ae049c2996e8d8d8";
    fetchSubmodules = true;
    hash = "sha256-gcoHRFDznlISVJU/IveZc1m59HUytc39Pf+obIKY0hQ=";
  };

  spike = pkgs.spike.overrideAttrs (old: {
    src = pkgs.fetchFromGitHub {
      owner = "riscv";
      repo = "riscv-isa-sim";
      rev = "3e58f5ef626fa76dd6675f1f78c6cd8470e18727";
      sha256 = "sha256-A37a3e+YNHFpu3xWtidF14yvBLNM764o7tH1BdCesOY=";
    };

    doCheck = false;
    doInstallCheck = false;
    installCheckPhase = null;
  });
in rec {
  riscv-tests-orig = riscvPkgs.stdenv.mkDerivation {
    name = "riscv-tests-orig";
    src = riscvTestsSrc;

    enableParallelBuilding = true;

    nativeBuildInputs = with pkgs; [
      autoconf
    ];

    patchPhase = ''
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

  riscv-tests-elf = riscv-tests-orig.overrideAttrs (old: {
    name = "riscv-tests-elf";

    patchPhase = old.patchPhase + ''
      rm ./env/p/riscv_test.h
      cp ${./riscv_test.h} ./env/p/riscv_test.h
    '';
  });

  riscv-tests-bin = riscvPkgs.stdenv.mkDerivation {
    name = "riscv-tests-bin";
    src = riscv-tests-elf;

    buildPhase = ''
      mkdir -p $out/share/riscv-tests/{isa,mt,benchmarks}
      FLIST=$(find . -type f | grep -v "\.dump$" | sed -e '/readme.txt$/d' -e '/Makefile$/d' -e '/\.gitignore$/d')
      for BIN in $FLIST
      do
        riscv64-none-elf-objcopy -O binary $BIN $out/$BIN.bin
      done
    '';
  };

  riscv-tests-signatures = pkgs.stdenv.mkDerivation {
    name = "riscv-tests-signatures";
    src = riscv-tests-orig;

    nativeBuildInputs = [
      spike
      pkgs.dtc
    ];

    buildPhase = ''
      mkdir -p $out/share/riscv-tests/isa
      FLIST=$(find ./share/riscv-tests/isa/ -type f | grep -v "\.dump$" | sed -e '/readme.txt$/d' -e '/Makefile$/d' -e '/\.gitignore$/d') 
      for BIN in $FLIST
      do
        echo $BIN
        if [[ $BIN =~ "rv32" ]]
        then
          echo "rv32"
          spike --isa=rv32gc_ziccid_zfh_zicboz_svnapot_zicntr_zba_zbb_zbc_zbs --misaligned +signature=$out/$BIN.sig $BIN
        else
          echo "rv64"
          spike --isa=rv64gch_ziccid_zfh_zicboz_svnapot_zicntr_zba_zbb_zbc_zbs --misaligned +signature=$out/$BIN.sig $BIN
        fi
      done
    '';
  };

  riscv-tests = pkgs.buildEnv {
    name = "riscv-tests";
    paths = [
      riscv-tests-elf
      riscv-tests-bin
      riscv-tests-signatures
    ];
  };
}
