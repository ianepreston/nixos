{ pkgs }:
# The existing cache algorithm needs GNU utilities and Bash 4+, including on macOS.
pkgs.writeShellApplication {
  name = "llama-cpp-prune";
  runtimeInputs = with pkgs; [
    bash
    coreutils
    findutils
    gnugrep
    gnused
    curl
  ];
  text = ''
    export NO_PROXY=127.0.0.1,localhost
    exec bash ${../../../scripts/llm-prune-models.sh} "$@"
  '';
}
