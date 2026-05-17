{ pkgs, derivations }:
pkgs.stdenvNoCC.mkDerivation {
  name = "initramfs";
  version = "0.1.0";

  phases = [ "unpackPhase" "buildPhase" ];
  unpackPhase = pkgs.lib.concatStrings (map (der: 
    # make directories
    "${pkgs.findutils}/bin/find \"${der}\" -not -path \"${der}\" -type d -printf \"%P\\n\" | ${pkgs.findutils}/bin/xargs -I{} mkdir -p {}\n" +

    # copy over files
    "${pkgs.findutils}/bin/find \"${der}\" -type f,l -printf \"%P\\n\" | ${pkgs.findutils}/bin/xargs -I{} cp -a ${der}/{} {}\n\n"
  ) derivations) +
    
    # dynamic linker and init script
  ''
    ln -s /lib/libc.so lib/ld-musl-riscv64-sf.so.1
    ln -s /lib/libc.so lib/ld-musl-riscv64.so.1
    cp -a ${./init} init
  '';

  buildPhase = ''
    ${pkgs.findutils}/bin/find . | ${pkgs.cpio}/bin/cpio -o -H newc > $out
  '';
}
