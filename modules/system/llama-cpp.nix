# Inference owner: shared model contract, CUDA/systemd and Metal/launchd adapters.
# Operational notes live in _llama-cpp/README.md and the root README.
{ inputs, ... }:
{
  flake.modules.nixos.llama-cpp = import ./_llama-cpp/nixos.nix { inherit inputs; };
  flake.modules.darwin.llama-cpp = import ./_llama-cpp/darwin.nix;
}
