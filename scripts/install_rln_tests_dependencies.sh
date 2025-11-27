#!/usr/bin/env bash

# Install Anvil
FOUNDRY_VERSION="$1"
./scripts/install_anvil.sh "$FOUNDRY_VERSION"

#Install pnpm
./scripts/install_pnpm.sh