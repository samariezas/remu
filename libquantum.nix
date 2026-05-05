{ stdenv, fetchurl }:
stdenv.mkDerivation rec {
  pname = "libquantum";
  version = "1.0.0";

  src = fetchurl {
    url = "http://www.libquantum.de/files/libquantum-${version}.tar.gz";
    sha256 = "07xfcg8ryjjhy41pxpzhnbnsd4c68l969z5331323gjwz5002glk";
  };
}
