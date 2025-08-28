{ inputs, ... }:
{
  config.hostSpecs.penguin = {
    hostName = "penguin";
    inherit (inputs.nix-secrets) email;
  };
}
