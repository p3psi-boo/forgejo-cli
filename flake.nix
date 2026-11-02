{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      utils,
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      rec {
        packages.forgejo-cli = pkgs.stdenv.mkDerivation {
          pname = "forgejo-cli";
          version = "0.8.0-dev";
          src = pkgs.lib.cleanSource ./.;

          nativeBuildInputs = with pkgs; [
            zig
            git
            installShellFiles
          ];

          dontConfigure = true;

          env = {
            BUILD_TYPE = "flake";
          };

          buildPhase = ''
            runHook preBuild
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
            zig build -Doptimize=ReleaseSafe -Dbuild-type=flake --prefix $out
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            export HOME=$(mktemp -d)
            installShellCompletion --cmd fj \
              --bash <($out/bin/fj completion bash) \
              --fish <($out/bin/fj completion fish) \
              --zsh <($out/bin/fj completion zsh)
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "CLI tool for Forgejo";
            homepage = "https://codeberg.org/forgejo-contrib/forgejo-cli/";
            license = with licenses; [
              asl20 # or
              mit
            ];
          };
        };

        packages.default = packages.forgejo-cli;

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zig
            git
            zls
          ];
        };
      }
    );
}
