# OrcaSlicer - HM Simple Aspect
# Open (AGPL) FDM slicer; the deproprietary alternative to Bambu Studio
# for the Bambu Lab P1S. Printing goes through bambuddy's Virtual Printer
# (Proxy Mode): Orca talks the Bambu LAN protocol to bambuddy, which
# relays to the real printer on the IoT VLAN. See modules/apps/bambuddy.nix.
#
# Why this module patches a CA into Orca:
#   bambuddy's VP terminates the printer MQTT-over-TLS leg with a per-instance
#   self-signed cert chained to its own "Virtual Printer CA" (generated at
#   first run, persisted under bambuddy's data dir). OrcaSlicer/Bambu Studio
#   validate the printer-MQTT cert ONLY against their bundled Bambu Lab CA
#   store (share/OrcaSlicer/cert/printer.cer) and give no UI to add a CA.
#   Without bambuddy's CA in that bundle the SSDP detect step succeeds but the
#   MQTT TLS handshake is rejected. So we make Orca trust the bambuddy VP CAs.
#   (See bambuddy wiki: https://wiki.bambuddy.cool/features/virtual-printer/.)
#
# How we inject it WITHOUT recompiling Orca:
#   OrcaSlicer resolves its resources dir (incl. printer.cer) at runtime from
#   /proc/self/exe (FHS build, no env override). Editing the bundle via
#   `overrideAttrs` forces a full source recompile on every nixpkgs bump.
#   Instead we run Orca under bubblewrap and bind-mount a patched printer.cer
#   over the original store path — orca-slicer stays byte-for-byte as nixpkgs
#   ships it, so version bumps are a plain substitute (no compile). `--dev-bind
#   / /` keeps it transparent (display/D-Bus/GPU/files/network all pass
#   through); only the one cert file is shadowed.
#
# bambuddy-vp-ca.crt bundles the "Virtual Printer CA" from every host that
# runs bambuddy, since this workstation may print to any of them. The CAs are
# public certs (trust anchors, not secrets), safe to commit, and stable across
# container restarts (they live in bambuddy's persisted data dir). If a
# bambuddy instance's VP certs are ever regenerated (data dir wiped), refetch
# with:  ssh <host> cat /var/lib/containers/bambuddy/data/virtual_printer/certs/bbl_ca.crt
_: {
  flake.modules.homeManager.orca-slicer =
    { pkgs, ... }:
    let
      # printer.cer with bambuddy's VP CAs appended — built by concatenation,
      # not by rebuilding orca-slicer. Cats the upstream bundle (fails the
      # build loudly if that path ever moves on a version bump).
      patchedCert = pkgs.runCommand "orca-printer-cer-bambuddy" { } ''
        cat ${pkgs.orca-slicer}/share/OrcaSlicer/cert/printer.cer ${./bambuddy-vp-ca.crt} > "$out"
      '';
      certPath = "${pkgs.orca-slicer}/share/OrcaSlicer/cert/printer.cer";
      orca-slicer = pkgs.symlinkJoin {
        name = "orca-slicer-bambuddy-${pkgs.orca-slicer.version}";
        paths = [ pkgs.orca-slicer ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        # Replace the launcher with a bwrap shim that overlays the patched
        # cert. The bundled OrcaSlicer.desktop uses `Exec=orca-slicer` (bare
        # name, PATH-resolved), so it picks up this wrapper automatically.
        postBuild = ''
          rm -f "$out/bin/orca-slicer"
          makeWrapper ${pkgs.bubblewrap}/bin/bwrap "$out/bin/orca-slicer" \
            --add-flags "--dev-bind / / --ro-bind ${patchedCert} ${certPath} -- ${pkgs.orca-slicer}/bin/orca-slicer"
        '';
      };
    in
    {
      home.packages = [ orca-slicer ];
    };
}
