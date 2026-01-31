#!/usr/bin/env bash

# Build native C dependencies from nimble cache paths
# This script builds the C libraries required by Nim packages

set -e

# Get package paths from nimble
BEARSSL_PATH=$(nimble path bearssl 2>/dev/null || echo "")
SECP256K1_PATH=$(nimble path secp256k1 2>/dev/null || echo "")
NAT_TRAVERSAL_PATH=$(nimble path nat_traversal 2>/dev/null || echo "")
LIBBACKTRACE_PATH=$(nimble path libbacktrace 2>/dev/null || echo "")

# Optional cross-compilation support
CC="${CC:-cc}"
AR="${AR:-ar}"

echo "Building native dependencies..."
echo "CC=$CC"
echo "AR=$AR"

# Build BearSSL
if [ -n "$BEARSSL_PATH" ] && [ -d "$BEARSSL_PATH/bearssl/csources" ]; then
    echo "Building BearSSL..."
    make -C "$BEARSSL_PATH/bearssl/csources" lib CC="$CC" AR="$AR"
else
    echo "Warning: BearSSL path not found or csources missing"
fi

# Build secp256k1
if [ -n "$SECP256K1_PATH" ] && [ -d "$SECP256K1_PATH/vendor/secp256k1" ]; then
    echo "Building secp256k1..."
    SECP_DIR="$SECP256K1_PATH/vendor/secp256k1"
    if [ ! -f "$SECP_DIR/configure" ]; then
        echo "Running autogen.sh..."
        (cd "$SECP_DIR" && ./autogen.sh)
    fi
    if [ ! -f "$SECP_DIR/Makefile" ]; then
        echo "Running configure..."
        (cd "$SECP_DIR" && ./configure --enable-module-recovery --enable-module-ecdh CC="$CC")
    fi
    make -C "$SECP_DIR" CC="$CC"
else
    echo "Warning: secp256k1 path not found"
fi

# Build miniupnpc
if [ -n "$NAT_TRAVERSAL_PATH" ] && [ -d "$NAT_TRAVERSAL_PATH/vendor/miniupnp/miniupnpc" ]; then
    echo "Building miniupnpc..."
    make -C "$NAT_TRAVERSAL_PATH/vendor/miniupnp/miniupnpc" build/libminiupnpc.a CC="$CC" AR="$AR"
else
    echo "Warning: miniupnpc path not found"
fi

# Build libnatpmp
if [ -n "$NAT_TRAVERSAL_PATH" ] && [ -d "$NAT_TRAVERSAL_PATH/vendor/libnatpmp-upstream" ]; then
    echo "Building libnatpmp..."
    make -C "$NAT_TRAVERSAL_PATH/vendor/libnatpmp-upstream" libnatpmp.a CC="$CC" AR="$AR"
else
    echo "Warning: libnatpmp path not found"
fi

# Build libbacktrace
if [ -n "$LIBBACKTRACE_PATH" ]; then
    echo "Building libbacktrace..."
    make -C "$LIBBACKTRACE_PATH" BUILD_CXX_LIB=0 CC="$CC"
else
    echo "Warning: libbacktrace path not found"
fi

echo "Native dependencies built successfully!"
