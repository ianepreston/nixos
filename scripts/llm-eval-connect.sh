#!/usr/bin/env bash
# Reach HOST's llama-server and run `llm-eval.py <args>` against it (#555).
#
#   scripts/llm-eval-connect.sh <host> <llm-eval.py subcommand> [args...]
#
# Shared by `task llm:eval` and `task llm:gate`. On the target host itself it
# talks to loopback. Elsewhere it adds a port forward to the existing ssh
# master, failing fast without one rather than prompting for a FIDO touch,
# and removes the forward on exit. The API key is read with sudo from the
# rendered env file, the same source `llm:models` uses.
#
# Sets LLM_EVAL_SSH=<host> when the host is remote, so `gate` runs its
# nvidia-smi/ps probes over the same master instead of locally.
set -euo pipefail

host=$1
shift

port=$(nix eval --raw --apply toString ".#nixosConfigurations.$host.config.myLlamaCpp.operator.port")
key_file=$(nix eval --raw ".#nixosConfigurations.$host.config.myLlamaCpp.operator.apiKeyFile")

if [ "$(hostname)" = "$host" ]; then
  endpoint="http://127.0.0.1:$port"
  LLAMA_API_KEY=$(sudo grep -oP 'LLAMA_API_KEY=\K.*' "$key_file")
  unset LLM_EVAL_SSH
else
  ssh -O check "$host" 2>/dev/null || {
    echo "no ssh master for $host; open one first (ssh $host)" >&2
    exit 1
  }
  lport=$((20000 + RANDOM % 10000))
  ssh -O forward -L "$lport:127.0.0.1:$port" "$host"
  trap 'ssh -O cancel -L "$lport:127.0.0.1:$port" "$host" 2>/dev/null || true' EXIT
  endpoint="http://127.0.0.1:$lport"
  LLAMA_API_KEY=$(ssh -n "$host" "sudo grep -oP 'LLAMA_API_KEY=\K.*' $key_file")
  export LLM_EVAL_SSH=$host
fi
export LLAMA_API_KEY

nix shell --inputs-from . nixpkgs#python3 -c \
  python3 scripts/llm-eval.py "$@" --endpoint "$endpoint" --host "$host"
