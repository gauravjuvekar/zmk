{
  description = "Local upstream ZMK firmware builds (Nordic ARM boards)";

  inputs = {
    # This stable package set provides the tested ARM GCC 13.3 toolchain.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Match app/west.yml and its imported Zephyr west.yml. No west update or
    # network access is needed during compilation; flake.lock pins every source.
    # Update these pins together when upgrading ZMK. Nix handles initial source
    # and tool downloads; cached builds also work with nix build --offline.
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
          # These modules cover Nordic ARM boards; other MCU families need their HALs.
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
          # lib.mkFirmware takes a host system string, then these build arguments.
          # src defaults to the checked-out app; config selects a ZMK config directory.
          # extraModules and cmakeFlags allow other boards and build options.
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
              # Compile firmware locally rather than substituting prebuilt images.
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
          # The original mylayout-lp and mylayout-wl config branches share a keymap.
          # config/ preserves it with quick_tap_ms migrated to quick-tap-ms.
          # Board definitions preserve the vendor flash partitions and oscillator
          # choices (202205 RC, 202207 crystal); both revisions use nRF52833.
          keyboards = {
            lp = "202207";
            wl = "202205";
          };
          roles = {
            central-left = {
              side = "left";
              shield = "slicemk_ergodox_leftcentral";
            };
            peripheral-right = {
              side = "right";
              shield = "slicemk_ergodox_right";
            };
          };
          firmware = pkgs.lib.mapAttrs (
            keyboard: revision:
            pkgs.lib.mapAttrs (
              role: target:
              mkFirmware {
                name = "mylayout-${keyboard}-${role}";
                board = "slicemk_ergodox_${revision}_green_${target.side}";
                inherit (target) shield;
                config = ./config;
              }
            ) roles
          ) keyboards;
          # Each keyboard target contains role directories so .config and DTS
          # outputs remain distinguishable. Individual half targets are derived
          # from the same matrix, e.g. lp-central-left and wl-peripheral-right.
          packages = pkgs.lib.concatMapAttrs (
            keyboard: halves:
            {
              ${keyboard} = pkgs.linkFarm "zmk-mylayout-${keyboard}" (
                pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) halves
              );
            }
            // pkgs.lib.mapAttrs' (role: package: pkgs.lib.nameValuePair "${keyboard}-${role}" package) halves
          ) firmware;
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
      # The default builds both LP halves. Flash matching upstream halves together:
      # vendor peripherals use a different split implementation. Clear old bonds
      # when migrating. Compile and UF2 validation do not replace hardware testing.
      packages = forAllSystems (
        system:
        let
          packages = (forSystem system).packages;
        in
        packages // { default = packages.lp; }
      );
      # For incremental builds, enter nix develop and run:
      # cmake -S app -B build/local -G Ninja \
      #   -DBOARD=slicemk_ergodox_202207_green_left -DBOARD_ROOT="$PWD/app" \
      #   -DSHIELD=slicemk_ergodox_leftcentral -DZMK_CONFIG="$PWD/config"
      # cmake --build build/local --parallel
      # Add new config files to Git so Nix includes them in the source snapshot.
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
