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
      libquantum = (pkgs.callPackage ./libquantum.nix {});
      libquantum-wrap = (pkgs.callPackage ./libquantum-wrap { inherit libquantum; });
      zig-build-inputs = with pkgs; [
        glibc
        libelf
        zig

        tests.spike-mod
        dtc

        libquantum
        libquantum-wrap
      ];

      run-script = pkgs.writeScript "run.sh" ''
        #!/usr/bin/env bash
        set -eu
        cd "$(dirname "$0")"
        
        if [ -x "../remu.AppImage" ]; then
            EMULATOR="../remu.AppImage"
        elif [ -x "./remu.AppImage" ]; then
            EMULATOR="./remu.AppImage"
        else
            echo "Klaida: nerastas remu.AppImage failas." >&2
            exit 1
        fi
        
        set -x
        "$EMULATOR" \
            ./opensbi.bin \
            ./machine.dtb \
            ./linux \
            ./initrd
      '';
    in rec {
      packages.${system} = with tests; {
        inherit riscv-tests
                riscv-tests-orig;
      } // (with image; {
        image-linux = linux;
        image-initramfs = initramfs;
        image-opensbi = opensbi;
        image-tcc = tcc;
        image-ncurses = ncurses;
        image-vim = vim;

        remu = pkgs.stdenv.mkDerivation {
          name = "remu";
          version = "0.0.1";
          src = ./.;

          buildInputs = zig-build-inputs;
          
          buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache"
              zig build \
                  --color off \
                  --summary all \
                  -Doptimize=ReleaseSafe
          '';

          installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/remu $out/bin
          '';

          meta.mainProgram = "remu";
        };

        remu-sandybridge = pkgs.stdenv.mkDerivation {
          name = "remu";
          version = "0.0.1";
          src = ./.;

          buildInputs = zig-build-inputs;
          
          # TODO: remove sandybridge target whenever MIF is not needed
          buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache"
              zig build \
                  --color off \
                  --summary all \
                  -Dcpu=sandybridge \
                  -Doptimize=ReleaseSafe
          '';

          installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/remu $out/bin
          '';

          meta.mainProgram = "remu";
        };

        remu-package = pkgs.stdenv.mkDerivation {
          name = "remu-package";
          version = "0.0.1";

          unpackPhase = ''true'';

          buildPhase = ''
            mkdir -p remu-package
            cp ${image.initramfs} ./remu-package/initrd
            cp ${image.linux}/Image ./remu-package/linux
            cp ${image.opensbi}/fw_dynamic.bin ./remu-package/opensbi.bin
            cp ${run-script} ./remu-package/run.sh
            chmod +x ./remu-package/run.sh
            ${pkgs.dtc}/bin/dtc ${./remu.dts} > ./remu-package/machine.dtb
            tar cvzf $out ./remu-package
          '';
        };
      });

      devShells.${system} = {
        default = pkgs.mkShell {
          buildInputs = zig-build-inputs;
        };
        riscv = tests.riscv-devshell;
        riscv-musl = pkgsCross.mkShell { };
      };

      apps.${system} = {
        tests = {
          type = "app";
          program = "${pkgs.writeShellScript "run_riscv_tests" ''
            zig build
            ./zig-out/bin/remu full ${tests.riscv-tests}/share/riscv-tests/
          ''}";
        };
      
        default = {
          type = "app";
          program = "${pkgs.writeShellScript "run_riscv_tests" ''
            ${packages.${system}.remu}/bin/remu \
                ${image.opensbi}/fw_dynamic.bin \
                <(cat ${./remu.dts} | ${pkgs.dtc}/bin/dtc) \
                ${image.linux}/Image \
                ${image.initramfs}
          ''}";

        };
      };
    };
}
