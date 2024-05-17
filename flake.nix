{
  description = ''
    A Nix flake for working with Tidal Cycles. https://tidalcycles.org/
  '';

  inputs = {
    dirt-samples-src = {
      url = "github:tidalcycles/dirt-samples/master";
      flake = false;
    };
    utils = {
      url = "github:numtide/flake-utils";
    };
    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
    superdirt-src = {
      url = "github:musikinformatik/superdirt/master"; # use `develop` branch as its default?
      flake = false;
    };
    tidal-src = {
      url = "github:tidalcycles/tidal/main";
      flake = false;
    };
    vim-tidal-src = {
      url = "github:tidalcycles/vim-tidal/master";
      flake = false;
    };
    vowel-src = {
      url = "github:supercollider-quarks/vowel/master";
      flake = false;
    };
  };

  outputs = inputs: let
    # TODO: We should support darwin (macOS) here, supercollider package
    # currently lacks support.
    utils.supportedSystems = [
      "aarch64-linux"
      "i686-linux"
      "x86_64-linux"
      # "aarch64-darwin"
      # "x86_64-darwin"
    ];
    utils.eachSupportedSystem =
      inputs.utils.lib.eachSystem utils.supportedSystems;

    mkPackagesOverlay = final: prev: let
      quarklib = prev.callPackage ./quark/lib.nix {};
      ghcWithTidal = prev.haskellPackages.ghcWithPackages (p: [p.tidal]);

      # SuperCollider quarks that are necessary for Tidal.
      dirt-samples = quarklib.mkQuark {
        name = "Dirt-Samples";
        src = inputs.dirt-samples-src;
      };
      vowel = quarklib.mkQuark {
        name = "Vowel";
        src = inputs.vowel-src;
      };
      superdirt = quarklib.mkQuark {
        name = "SuperDirt";
        src = inputs.superdirt-src;
        dependencies = [dirt-samples vowel];
      };

      # Supercollider with the SC3 plugins used by tidal.
      supercollider = prev.supercollider-with-plugins.override {
        plugins = [prev.supercolliderPlugins.sc3-plugins];
      };

      # A sclang command with superdirt included via conf yaml.
      sclang-with-superdirt = prev.writeShellApplication {
        name = "sclang-with-superdirt";
        runtimeInputs = [supercollider];
        text = ''
          ${supercollider}/bin/sclang -l "${final.superdirt}/sclang_conf.yaml" "$@"
        '';
      };

      # A very simple default superdirt start file.
      superdirt-start-sc = prev.writeText "superdirt-start.sc" "SuperDirt.start;";

      # Run `SuperDirt.start` in supercollider, ready for tidal.
      superdirt-start = prev.writeShellApplication {
        name = "superdirt-start";
        runtimeInputs = [supercollider];
        text = ''
          start_script="''${1:-${superdirt-start-sc}}"

          if [ "$start_script" == "-h" ] || [ "$start_script" == "--help" ]; then
            echo "Usage: superdirt-start [script]"
            echo
            echo "Start superdirt, optionally running a custom start script."
            echo
            echo "Options:"
            echo "  -h --help    Show this screen."
            exit
          fi

          if [ ! -e "$start_script" ]; then
            echo "The script \"$start_script\" does not exist, aborting."
            exit 1
          fi

          ${final.sclang-with-superdirt}/bin/sclang-with-superdirt "$start_script"
        '';
      };

      # Installs SuperDirt under your user's supercollider quarks.
      superdirt-install = prev.writeShellScriptBin "superdirt-install" ''
        ${supercollider}/bin/sclang ${final.superdirt}/install.scd
      '';

      # Run the tidal interpreter (ghci running BootTidal.hs).
      tidal = prev.writeShellScriptBin "tidal" ''
        ${final.ghcWithTidal}/bin/ghci -ghci-script ${inputs.tidal-src}/BootTidal.hs
      '';

      # Vim plugin for tidalcycles.
      vim-tidal = prev.vimUtils.buildVimPluginFrom2Nix {
        pname = "vim-tidal";
        version = "master";
        src = inputs.vim-tidal-src;
        postInstall = let
          # A vimscript file to set Nix defaults for ghci and `BootTidal.hs`.
          defaults-file = prev.writeText "vim-tidal-defaults.vim" ''
            " Prepend defaults provided by Nix packages.
            if !exists("g:tidal_ghci")
              let g:tidal_ghci = "${final.ghcWithTidal}/bin/ghci"
            endif
            if !exists("g:tidal_sclang")
              let g:tidal_sclang = "${final.sclang-with-superdirt}/bin/sclang-with-superdirt"
            endif
            if !exists("g:tidal_boot_fallback")
              let g:tidal_boot_fallback = "${inputs.tidal-src}/BootTidal.hs"
            endif
            if !exists("g:tidal_sc_boot_fallback")
              let g:tidal_sc_boot_fallback = "${superdirt-start-sc}"
            endif
          '';
        in ''
          # Prepend a line to `plugin/tidal.vim` to source the defaults.
          mv $out/plugin/tidal.vim $out/plugin/tidal.vim.old
          cat ${defaults-file} $out/plugin/tidal.vim.old > $out/plugin/tidal.vim
          rm $out/plugin/tidal.vim.old

          # Remove unnecessary files.
          rm -r $out/bin
          rm $out/Makefile
          rm $out/Tidal.ghci
        '';
        meta = {
          homepage = "https://github.com/tidalcycles/vim-tidal.vim";
          license = prev.lib.licenses.mit;
        };
      };
    in {
      inherit superdirt-start superdirt-install tidal sclang-with-superdirt ghcWithTidal quarklib superdirt;
      vimPlugins = prev.vimPlugins // {inherit vim-tidal;};
      supercollider-w-superdirt = supercollider;
    };

    overlays = rec {
      tidal = mkPackagesOverlay;
      default = tidal;
    };

    mkDevShells = pkgs: rec {
      # A shell that provides a set of commonly useful packages for tidal.
      tidal = pkgs.mkShell {
        name = "tidal";
        buildInputs = [
          pkgs.supercollider-w-superdirt
          pkgs.superdirt-start
          pkgs.superdirt-install
          pkgs.tidal
          pkgs.sclang-with-superdirt
        ];
        # Convenient access to a config providing all quarks required for Tidal.
        SUPERDIRT_SCLANG_CONF = "${pkgs.superdirt}/sclang_conf.yaml";
      };
      default = tidal;
    };

    templates = rec {
      tidal-project = {
        path = ./template;
        description = ''
          A standard nix flake template for a Tidal Cycles project.
        '';
      };
      default = tidal-project;
    };

    mkOutput = system: let
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [overlays.tidal];
      };
    in rec {
      packages = with pkgs; {
        inherit supercollider-w-superdirt superdirt-start superdirt-install tidal sclang-with-superdirt ghcWithTidal superdirt;
      };
      devShells = mkDevShells pkgs;
      formatter = pkgs.alejandra;
    };

    # The output for each system.
    systemOutputs = utils.eachSupportedSystem mkOutput;
  in
    # Merge the outputs and overlays.
    systemOutputs // {inherit overlays templates utils;};
}
