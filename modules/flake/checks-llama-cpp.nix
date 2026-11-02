_: {
  perSystem =
    { pkgs, ... }:
    let
      prunePackage = import ../system/_llama-cpp/prune-package.nix { inherit pkgs; };
    in
    {
      checks.llama-cpp-local =
        pkgs.runCommand "llama-cpp-local-tests"
          {
            nativeBuildInputs = [ pkgs.python3 ];
            __darwinAllowLocalNetworking = true;
          }
          ''
            export LLAMA_SERVE_SOURCE=${../system/_llama-cpp/serve.py}
            export LLAMA_PRUNE_TEST_COMMAND=${prunePackage}/bin/llama-cpp-prune
            python3 ${../../scripts/llm-local-test.py}
            touch "$out"
          '';
    };
}
