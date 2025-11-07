{ stdenv, fetchFromGitHub }:
stdenv.mkDerivation {
  name = "libprintf";
  version = "6.3.0";

  src = fetchFromGitHub {
      owner = "eyalroz";
      repo = "printf";
      rev = "f1b728cbd5c6e10dc1f140f1574edfd1ccdcbedb";
      hash = "sha256-HHp6uKEJv3HWEGgIBjeMsCXUSIPYTLwofjcDTswgSuA=";
  };

  buildPhase = ''
    $CC $CFLAGS -DPRINTF_SUPPORT_DECIMAL_SPECIFIERS=0 -DPRINTF_SUPPORT_EXPONENTIAL_SPECIFIERS=0 -Os -march=rv64g -mcmodel=medany -fvisibility=hidden -c src/printf/printf.c -Isrc -o printf.o
    $AR rcs libprintf.a printf.o
  '';
  
  installPhase = ''
    mkdir -p $out/lib $out/include
    cp libprintf.a $out/lib
    cp src/printf/printf.h $out/include
  '';
}
