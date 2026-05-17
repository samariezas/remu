{ pkgs, pkgsCross }:
pkgsCross.stdenv.mkDerivation {
  name = "ncurses";
  version = "6.6-20260425";
  src = pkgs.fetchzip {
    url = "https://invisible-mirror.net/archives/ncurses/current/ncurses-6.6-20260425.tgz";
    hash = "sha256-gR63ucE7yBGC/X1XRi/qfmROAN+L+QV+d9fuXWKDIsw=";
  };

  enableParallelBuilding = true;

  configureFlags = [ "--disable-stripping" "--without-manpages" "--disable-database" "--with-fallbacks=xterm" ];

  nativeBuildInputs = (with pkgs; [
    gcc
    binutils
  ]);

  dontFixup = true;
}
