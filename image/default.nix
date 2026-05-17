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
  initramfs = import ./initramfs.nix {
    inherit pkgs;
    derivations = [ musl busybox lua utils tcc samples vim ];
  };
  opensbi = import ./opensbi.nix { inherit pkgsCross pkgs; };
}
