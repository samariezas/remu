{ stdenv, libquantum }:
stdenv.mkDerivation {
  name = "quantum-wrap";
  version = "0.0.1";
  src = ./src;

  nativeBuildInputs = [ libquantum ];

  buildPhase = ''
    gcc -c -O2 -Wall quantum-wrap.c -o quantum-wrap.o
    ar rcs libquantum_wrap.a quantum-wrap.o
  '';

  installPhase = ''
    mkdir -p $out/include $out/lib
    cp libquantum_wrap.a $out/lib
    cp quantum-wrap.h $out/include
  '';
}
