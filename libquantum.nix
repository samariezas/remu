{ stdenv, fetchurl }:
stdenv.mkDerivation rec {
  pname = "libquantum";
  version = "1.0.0";

  src = fetchurl {
    url = "http://www.libquantum.de/files/libquantum-${version}.tar.gz";
    sha256 = "sha256-sPGl7JdoRXrJg1vVLDAX0nmsmcwN/+bOKt+Kx2KZeyw=";
  };
}
