{
  description = "lintsp — a reader-only Common Lisp linter";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        lintsp = pkgs.stdenv.mkDerivation {
          pname = "lintsp";
          version = "0.1.0";
          src = self;
          nativeBuildInputs = [ pkgs.sbcl ];
          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            # The saved core records this heap size as its default, so a
            # whole-tree run does not need to pass a runtime option.
            sbcl --dynamic-space-size 6144 --non-interactive --load build.lisp
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp lintsp $out/bin/lintsp
            runHook postInstall
          '';
          # The built image is ~50 MB; keep the source out of it.
          dontStrip = true;
          meta = {
            description = "Reader-only Common Lisp linter: parses your source with the host reader and reports structural pathologies";
            mainProgram = "lintsp";
            platforms = pkgs.lib.platforms.unix;
          };
        };
        default = lintsp;
      });

      apps = forAll (pkgs: rec {
        lintsp = {
          type = "app";
          program = "${self.packages.${pkgs.system}.lintsp}/bin/lintsp";
        };
        default = lintsp;
      });

      checks = forAll (pkgs: {
        lintsp = self.packages.${pkgs.system}.lintsp;
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell { packages = [ pkgs.sbcl ]; };
      });
    };
}
