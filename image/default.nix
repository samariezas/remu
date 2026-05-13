{ pkgs, pkgsCross }:
rec {
  musl = import ./musl.nix { inherit pkgsCross; };
  busybox = import ./busybox.nix { inherit pkgsCross pkgs; };
  lua = import ./lua.nix { inherit pkgsCross pkgs; };
  utils = import ./utils.nix { inherit pkgsCross pkgs; };

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
    derivations = [ musl busybox lua utils benchmark ];
  };
  opensbi = import ./opensbi.nix { inherit pkgsCross pkgs; };
}
