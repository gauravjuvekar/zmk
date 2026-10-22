{
  description = "Local upstream ZMK firmware builds (Nordic ARM boards)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Match app/west.yml and its imported Zephyr west.yml. No west update or
    # network access is needed during compilation; flake.lock pins every source.
    zephyr = {
      url = "github:zmkfirmware/zephyr/v4.1.0+zmk-fixes";
      flake = false;
    };
    cmsis = {
      url = "github:zephyrproject-rtos/cmsis/d1b8b20b6278615b00e136374540eb1c00dcabe7";
      flake = false;
    };
    hal-nordic = {
      url = "github:zephyrproject-rtos/hal_nordic/37ca068d7b013fb65a2acc9306bffa48a3e72839";
      flake = false;
    };
    segger = {
      url = "github:zephyrproject-rtos/segger/cf56b1d9c80f81a26e2ac5727c9cf177116a4692";
      flake = false;
    };
    tinycrypt = {
      url = "github:zephyrproject-rtos/tinycrypt/1012a3ebee18c15ede5efc8332ee2fc37817670f";
      flake = false;
    };
    mbedtls = {
      url = "github:zephyrproject-rtos/mbedtls/4952e1328529ee549d412b498ea71c54f30aa3b1";
      flake = false;
    };
    lvgl = {
      url = "github:zmkfirmware/lvgl/f1db87ee98f1810328a8419572fa42a3b5f352ae";
      flake = false;
    };
    nanopb = {
      url = "github:zephyrproject-rtos/nanopb/7307ce399b81ddcb3c3a5dc862c52d4754328d38";
      flake = false;
    };
    studio-messages = {
      url = "github:zmkfirmware/zmk-studio-messages/6cb4c283e76209d59c45fbcb218800cd19e9339d";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      forSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          python = pkgs.python3.withPackages (
            p: with p; [
              west
              pyyaml
              pykwalify
              pyelftools
              packaging
              intelhex
              anytree
              jinja2
              ply
              jsonschema
              protobuf
            ]
          );
          tools = [
            pkgs.cmake
            pkgs.ninja
            pkgs.dtc
            pkgs.gcc-arm-embedded-13
            python
            pkgs.git
          ];
          # Zephyr derives module names from directory basenames when module.yml
          # omits a name. Preserve west's names instead of Nix store basenames.
          moduleSources = {
            inherit (inputs)
              cmsis
              segger
              tinycrypt
              mbedtls
              lvgl
              nanopb
              ;
            hal_nordic = inputs.hal-nordic;
            zmk-studio-messages = inputs.studio-messages;
          };
          moduleTree = pkgs.linkFarm "zmk-zephyr-modules" (
            pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) moduleSources
          );
          modules = map (name: "${moduleTree}/${name}") (builtins.attrNames moduleSources);
          mkFirmware =
            {
              name,
              board,
              shield ? null,
              config ? null,
              cmakeFlags ? [ ],
              src ? self,
              extraModules ? [ ],
            }:
            pkgs.stdenvNoCC.mkDerivation {
              pname = "zmk-${name}";
              version = "${self.shortRev or self.dirtyShortRev or "local"}";
              inherit src;
              preferLocalBuild = true;
              allowSubstitutes = false;
              nativeBuildInputs = tools;
              dontUseCmakeConfigure = true;
              dontUseNinjaBuild = true;
              dontUseNinjaInstall = true;
              dontFixup = true;
              ZEPHYR_BASE = inputs.zephyr.outPath;
              ZEPHYR_TOOLCHAIN_VARIANT = "gnuarmemb";
              GNUARMEMB_TOOLCHAIN_PATH = "${pkgs.gcc-arm-embedded-13}";
              buildPhase = ''
                runHook preBuild
                export HOME="$TMPDIR/home"
                export XDG_CACHE_HOME="$TMPDIR/cache"
                mkdir -p "$HOME" "$XDG_CACHE_HOME"
                cmake -S app -B build -G Ninja \
                  -DZephyr_DIR="$ZEPHYR_BASE/share/zephyr-package/cmake" \
                  -DBOARD=${pkgs.lib.escapeShellArg board} \
                  -DBOARD_ROOT="$PWD/app" \
                  -DZEPHYR_MODULES=${
                    pkgs.lib.escapeShellArg (pkgs.lib.concatStringsSep ";" (modules ++ extraModules))
                  } \
                  ${pkgs.lib.optionalString (shield != null) "-DSHIELD=${pkgs.lib.escapeShellArg shield}"} \
                  ${
                    pkgs.lib.optionalString (config != null) "-DZMK_CONFIG=${pkgs.lib.escapeShellArg (toString config)}"
                  } \
                  ${pkgs.lib.escapeShellArgs cmakeFlags}
                cmake --build build --parallel "$NIX_BUILD_CORES"
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p "$out"
                for ext in uf2 hex bin elf; do
                  if test -f "build/zephyr/zmk.$ext"; then
                    cp "build/zephyr/zmk.$ext" "$out/${name}.$ext"
                  fi
                done
                cp build/zephyr/.config "$out/zephyr.config"
                cp build/zephyr/zephyr.dts "$out/zephyr.dts"
                runHook postInstall
              '';
            };
          keyboard =
            if builtins.pathExists ./nix/keyboard.nix then
              import ./nix/keyboard.nix
            else
              {
                board = "nice_nano//zmk";
                shield = "corne_left";
                name = "upstream-corne-left";
              };
          firmware = mkFirmware (
            (builtins.removeAttrs keyboard [ "peripheralBoard" ])
            // pkgs.lib.optionalAttrs (builtins.pathExists ./config) { config = ./config; }
          );
          peripheral = mkFirmware {
            name = "${keyboard.name}-peripheral-right";
            board = keyboard.peripheralBoard;
            shield = "slicemk_ergodox_right";
            config = ./config;
          };
          packages = {
            default = firmware;
            central-left = firmware;
          }
          // pkgs.lib.optionalAttrs (keyboard ? peripheralBoard) { peripheral-right = peripheral; };
        in
        {
          inherit
            pkgs
            tools
            modules
            mkFirmware
            packages
            ;
        };
    in
    {
      packages = forAllSystems (system: (forSystem system).packages);
      devShells = forAllSystems (
        system:
        let
          s = forSystem system;
        in
        {
          default = s.pkgs.mkShell {
            packages = s.tools;
            ZEPHYR_BASE = inputs.zephyr.outPath;
            CMAKE_PREFIX_PATH = "${inputs.zephyr}/share/zephyr-package/cmake";
            ZEPHYR_MODULES = nixpkgs.lib.concatStringsSep ";" s.modules;
            ZEPHYR_TOOLCHAIN_VARIANT = "gnuarmemb";
            GNUARMEMB_TOOLCHAIN_PATH = "${s.pkgs.gcc-arm-embedded-13}";
          };
        }
      );
      lib.mkFirmware = system: (forSystem system).mkFirmware;
      formatter = forAllSystems (system: (forSystem system).pkgs.nixfmt);
    };
}
