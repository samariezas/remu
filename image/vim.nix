{ pkgs, pkgsCross, ncurses }:
pkgsCross.stdenv.mkDerivation rec {
  name = "vim";
  version = "v9.2.0461";
  src = pkgs.fetchgit {
    url = "https://github.com/vim/vim.git";
    hash = "sha256-l2KFbDFYbmZuT9++ZDnbiSdNnhpbldccOd0CLgooJzQ=";
    rev = version;
  };

  configureFlags = [ "--with-features=tiny" "--with-tlib=ncursesw" ];
  buildInputs = [ ncurses ];

  enableParallelBuilding = true;

  fixupPhase = ''
    ${pkgs.findutils}/bin/find $out -executable -type f -exec patchelf --interpreter /lib/ld-musl-riscv64-sf.so.1 {} \;
  '';
}
