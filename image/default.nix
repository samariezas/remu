{ pkgs, pkgsCross }:
rec {
  musl = import ./musl.nix { inherit pkgsCross; };
  busybox = import ./busybox.nix { inherit pkgsCross pkgs; };
  lua = import ./lua.nix { inherit pkgsCross pkgs; };

  linux = import ./linux.nix { inherit pkgsCross pkgs; };
  initramfs = import ./initramfs.nix {
    inherit pkgs;
    derivations = [ musl busybox lua ];
  };
  opensbi = import ./opensbi.nix { inherit pkgsCross pkgs; };
}
