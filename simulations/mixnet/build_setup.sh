#!/bin/bash
cd "$(dirname "$0")"
cd ../..

echo "Building credentials setup script..."
nim c -d:release --mm:refc \
    --passL:"-L$(pwd)/vendor/zerokit/target/release -lrln" \
    -o:simulations/mixnet/setup_credentials \
    simulations/mixnet/setup_credentials.nim 2>&1 | tail -20

cd simulations/mixnet
if [ -f "setup_credentials" ]; then
    echo ""
    echo "Running setup..."
    echo ""

    # Clean up old files first
    rm -f rln_tree.db rln_keystore_*.json

    # Run the setup
    ./setup_credentials

    # Verify output
    if [ -f "rln_tree.db" ]; then
        echo ""
        echo "Tree file ready at: $(pwd)/rln_tree.db"
        ls -la rln_keystore_*.json 2>/dev/null | wc -l | xargs -I {} echo "Generated {} keystore files"
    fi
else
    echo "Build failed - setup_credentials not found"
    exit 1
fi
