{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      tests = import ./tests { inherit pkgs; };
    in {
      packages.${system} = with tests; {
        inherit riscv-tests
                riscv-tests-orig
                riscv-tests-elf;
      };

      devShells.${system} = {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            glibc
            libelf
            zig
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
