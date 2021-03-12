#!/usr/bin/env bash
set -e
set -x

TLBX=$(dirname $PWD)
TMP=$(mktemp -d)
HASH=$(git rev-parse HEAD)
cp -r dummyCoqLib/* $TMP
cd $TMP
nix-shell $TLBX --run generateNixDefault
mkdir -p .nix
echo "\"$HASH\"" > .nix/coq-nix-toolbox.nix
nix-shell --run "ppNixEnv"
nix-shell --run "ppTaskSet"
nix-shell --run "ppCI"
nix-shell --run "exit 0"
exit $?
