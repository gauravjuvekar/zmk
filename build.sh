#!/bin/sh
set -eu

cd -- "$(dirname -- "$0")"

nix build .#lp --out-link result-lp "$@"
nix build .#wl --out-link result-wl "$@"
