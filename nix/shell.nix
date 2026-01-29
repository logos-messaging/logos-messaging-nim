{
  pkgs ? import <nixpkgs> { },
  nim ? null,
}:

pkgs.mkShell {
  inputsFrom = [
    pkgs.androidShell
  ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
    pkgs.libiconv
    pkgs.darwin.apple_sdk.frameworks.Security
  ];

  buildInputs = with pkgs; [
    git
    nim
    cargo
    rustup
    rustc
    cmake
  ];
}
