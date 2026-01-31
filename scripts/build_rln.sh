#!/usr/bin/env bash

# This script is used to build the rln library for the current platform.
# - If vendor/zerokit exists: builds from source
# - Otherwise: downloads prebuilt binary from GitHub releases

set -e

build_dir=$1
rln_version=$2
output_filename=$3

[[ -z "${build_dir}" ]]       && { echo "No build directory specified"; exit 1; }
[[ -z "${rln_version}" ]]     && { echo "No rln version specified";     exit 1; }
[[ -z "${output_filename}" ]] && { echo "No output filename specified"; exit 1; }

# Build from source if vendor exists
if [[ -d "${build_dir}/rln" ]]; then
    echo "Building RLN from source (${build_dir})..."

    detected_OS=$(uname -s)
    if [[ "$detected_OS" == MINGW* || "$detected_OS" == MSYS* ]]; then
        submodule_version=$(cargo metadata --format-version=1 --no-deps --manifest-path "${build_dir}/rln/Cargo.toml" | sed -n 's/.*"name":"rln","version":"\([^"]*\)".*/\1/p')
    else
        submodule_version=$(cargo metadata --format-version=1 --no-deps --manifest-path "${build_dir}/rln/Cargo.toml" | jq -r '.packages[] | select(.name == "rln") | .version')
    fi

    if [[ "v${submodule_version}" != "${rln_version}" ]]; then
        echo "Warning: Source version (v${submodule_version}) does not match expected (${rln_version})"
    fi

    cargo build --release -p rln --manifest-path "${build_dir}/rln/Cargo.toml"
    cp "${build_dir}/target/release/librln.a" "${output_filename}"
    echo "Built ${output_filename} from source"
    exit 0
fi

# Download prebuilt binary
host_triplet=$(rustc --version --verbose | awk '/host:/{print $2}')
tarball="${host_triplet}-stateless-rln.tar.gz"

if curl --silent --fail-with-body -L \
  "https://github.com/vacp2p/zerokit/releases/download/$rln_version/$tarball" \
  -o "${tarball}";
then
    echo "Downloaded ${tarball}"
    tar -xzf "${tarball}"
    mv "release/librln.a" "${output_filename}"
    rm -rf "${tarball}" release
else
    echo "Failed to download ${tarball}"
    echo "Run 'make vendors' to clone zerokit and build from source"
    exit 1
fi
