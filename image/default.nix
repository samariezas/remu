{ pkgs, pkgsCross }:
rec {
  musl = import ./musl.nix { inherit pkgsCross; };
  busybox = import ./busybox.nix { inherit pkgsCross pkgs; };
  lua = import ./lua.nix { inherit pkgsCross pkgs; };
  utils = import ./utils.nix { inherit pkgsCross pkgs; };
  tcc = import ./tcc.nix { inherit pkgsCross pkgs; };

  linux = import ./linux.nix { inherit pkgsCross pkgs; };
  initramfs = import ./initramfs.nix {
    inherit pkgs;
    derivations = [ musl busybox lua utils tcc ];
  };
  opensbi = import ./opensbi.nix { inherit pkgsCross pkgs; };
}
