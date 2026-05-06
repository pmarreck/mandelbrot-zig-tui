{
  description = "Mandelbrot TUI Explorer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "mandelbrot";
        version = "0.1.0";
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export HOME=$TMPDIR
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
            zig build -Doptimize=ReleaseFast --prefix $out
          '';
          dontInstall = true;
        };

        checks = {
          build = self.packages.${system}.default;
          test = pkgs.stdenv.mkDerivation {
            pname = "${pname}-test";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ pkgs.zig ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              timeout 600 zig build test || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };
          # Bash-driven CLI smoke tests (--single-frame outputs, error-code
          # contracts for --kitty without support, etc.). Pulls bash but no
          # extra runtime deps.
          cli-test = pkgs.stdenv.mkDerivation {
            pname = "${pname}-cli-test";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ pkgs.zig pkgs.bash ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              zig build -Doptimize=ReleaseFast
              bash tests/cli/test_cli.bash ./zig-out/bin/mandelbrot
            '';
            installPhase = ''
              mkdir -p $out
              echo "cli tests passed" > $out/result
            '';
          };
          # PTY-driven integration tests via tmux. Tmux is pulled in *only*
          # when running this check (not when entering the dev shell).
          # Run via: nix flake check  (or)  nix build .#checks.<system>.tmux-test
          tmux-test = pkgs.stdenv.mkDerivation {
            pname = "${pname}-tmux-test";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ pkgs.zig pkgs.bash pkgs.tmux pkgs.gnugrep pkgs.gawk pkgs.coreutils ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              zig build -Doptimize=ReleaseFast
              bash tests/integration/test_tmux.bash ./zig-out/bin/mandelbrot
            '';
            installPhase = ''
              mkdir -p $out
              echo "tmux tests passed" > $out/result
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            hyperfine
          ];
        };
      });
}
