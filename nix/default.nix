{
  pkgs,
  src ? ../.,
  # Nimbus-build-system package.
  nim ? null,
  # Options: 0,1,2
  verbosity ? 1,
  # Make targets
  targets ? ["libwaku-android-arm64"],
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? ["x86_64-linux" "aarch64-linux"],
  abidir ? null,
  zerokitRln,
}:

assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;

  tools = pkgs.callPackage ./tools.nix {};
  revision = lib.substring 0 8 (src.rev or src.dirtyRev or "00000000");
  version = tools.findKeyValue "^version = \"([a-f0-9.-]+)\"$" ../waku.nimble;

  androidManifest = "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"com.example.mylibrary\" />";

in stdenv.mkDerivation {
  pname = "logos-messaging-nim";
  version = "${version}-${revision}";

  inherit src;

  # Dependencies that should exist in the runtime environment.
  buildInputs = with pkgs; [
    openssl gmp zip
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
  in with pkgs; [
    nim cmake which zerokitRln nim-unwrapped-2_2 fakeGit
  ] ++ lib.optionals stdenv.isDarwin [
    pkgs.darwin.cctools gcc # Necessary for libbacktrace
  ];

  # Environment variables required for Android builds
  ANDROID_SDK_ROOT="${pkgs.androidPkgs.sdk}";
  ANDROID_NDK_HOME="${pkgs.androidPkgs.ndk}";
  # Disable CPU optimizations that make binary not portable.
  NIMFLAGS = "-d:disableMarchNative";
  # Avoid Nim cache permission errors.
  XDG_CACHE_HOME = "/tmp";

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "LIBRLN_FILE=${zerokitRln}/lib/librln.${if abidir != null then "so" else "a"}"
    # Built from nimbus-build-system via flake.
    "USE_SYSTEM_NIM=1"
  ];

  configurePhase = ''
    patchShebangs . vendor/nimbus-build-system > /dev/null
    make nimbus-build-system-paths
    make nimbus-build-system-nimble-dir
    ln -s waku.nimble waku.nims
  '';

  installPhase = if abidir != null then ''
    mkdir -p $out/jni
    cp -r ./build/android/${abidir}/* $out/jni/
    echo '${androidManifest}' > $out/jni/AndroidManifest.xml
    cd $out && zip -r libwaku.aar *
  '' else ''
    mkdir -p $out/bin $out/lib $out/include
    cp build/waku* $out/bin || true
    cp build/lib* $out/lib || true
    cp library/libwaku.h $out/include
  '';

  meta = with pkgs.lib; {
    description = "NWaku derivation to build libwaku for mobile targets using Android NDK and Rust.";
    homepage = "https://github.com/status-im/nwaku";
    license = licenses.mit;
    platforms = stableSystems;
  };
}
