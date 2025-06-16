{
  description = "Haskell bee";

  inputs = {
    systems.url = "github:nix-systems/x86_64-linux";
    nixpkgs.url = "github:nixos/nixpkgs?ref=24.11";
    flake-utils.url  = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, systems }@inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        ghcVersion = "966";

        buildInputs = with pkgs; [
          haskell.compiler."ghc${ghcVersion}"
          postgresql
          stdenv.cc.cc.lib
        ];
        
      in
        {
          devShells.default = pkgs.mkShell {
            inherit buildInputs;
          };
        }
    );
}
