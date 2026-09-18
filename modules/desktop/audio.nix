# Audio - Simple Aspect
# PipeWire audio stack
_: {
  flake.modules.nixos.audio =
    { pkgs, ... }:
    {
      services.pulseaudio.enable = false;
      security.rtkit.enable = true;
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
      };
      # pipewire-pulse serves the PulseAudio protocol but ships no client CLI;
      # pactl et al. live in the pulseaudio package, which nothing installs once
      # services.pulseaudio.enable = false. Steam and other pre-PipeWire software
      # shell out to pactl, so install the clients without the daemon.
      environment.systemPackages = [ pkgs.pulseaudio ];
    };
}
