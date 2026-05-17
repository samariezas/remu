{ pkgs, pkgsCross }:
rec {
  musl = import ./musl.nix { inherit pkgsCross; };
  busybox = import ./busybox.nix { inherit pkgsCross pkgs; };
  lua = import ./lua.nix { inherit pkgsCross pkgs; };
  utils = import ./utils.nix { inherit pkgsCross pkgs; };
  tcc = import ./tcc.nix { inherit pkgsCross pkgs; };
  ncurses = import ./ncurses.nix { inherit pkgsCross pkgs; };
  vim = import ./vim.nix { inherit pkgsCross pkgs ncurses; };

  samples = pkgs.stdenv.mkDerivation {
    name = "samples";
    src = ./samples;
    buildPhase = ''
      mkdir -p $out/samples
      cp -a * $out/samples
    '';
    dontFixup = true;
  };

  linux = import ./linux.nix { inherit pkgsCross pkgs; };
  benchmark = pkgs.writeScriptBin "benchmark" ''
    mkdir /results
    QBITS_CHOICES=$(seq 12 17)
    ITER_CHOICES=$(seq 1 500)
    for QBITS in $QBITS_CHOICES; do
        for ITER in $ITER_CHOICES; do
            echo "$QBITS:$ITER"
            time grover 128 $QBITS &> /results/$QBITS-it$ITER.txt
        done
    done
    time tar cvfz /results.tar.gz /results
  '';
  initramfs = import ./initramfs.nix {
    inherit pkgs;
    derivations = [ musl busybox lua utils benchmark tcc samples vim ];
  };
  opensbi = import ./opensbi.nix { inherit pkgsCross pkgs; };
}
