{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      pkgsCross = import nixpkgs {
        inherit system;
        crossSystem = {
          config = "riscv64-unknown-linux-musl";
          gcc = {
            arch = "rv64ima_zicsr_zifencei";
            abi = "lp64";
          };
        };
      };
      tests = import ./tests { inherit pkgs; };
      image = import ./image { inherit pkgs pkgsCross; };
    in {
      packages.${system} = with tests; {
        inherit riscv-tests
                riscv-tests-orig;
      } // (with image; {
        image-linux = linux;
        image-initramfs = initramfs;
        image-opensbi = opensbi;
      });

      devShells.${system} = {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            glibc
            libelf
            zig

            tests.spike-mod
            dtc
            rlwrap
          ];
        };
        riscv = tests.riscv-devshell;
      };

      apps.${system}.tests = {
        type = "app";
        program = "${pkgs.writeShellScript "run_riscv_tests" ''
          zig build
          ./zig-out/bin/bemu full ${tests.riscv-tests}/share/riscv-tests/
        ''}";
      };
    };
}
