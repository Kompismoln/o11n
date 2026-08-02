{ context, lib, ... }:
{
  options = {
    wallpaper = lib.mkOption {
      description = "path to wallpaper";
      type = lib.types.str;
    };
    vim-colorscheme = lib.mkOption {
      description = "name of vim colorscheme to use (check nixvim for supported schemes)";
      type = with lib.types; nullOr str;
      default = null;
    };
    colors = lib.mkOption {
      description = "flat color mapping with semantic colors attached";
      type = with lib.types; attrsOf str;
      default =
        let
          paletteFile = context.path + "/palette.json";
          palette =
            if builtins.pathExists paletteFile then builtins.fromJSON (builtins.readFile paletteFile) else null;
          colorNames = builtins.attrNames palette;

          colorNameValuePairs = builtins.concatMap (
            colorName:
            let
              shades = palette.${colorName};
            in
            map (shade: {
              name = "${colorName}-${shade}";
              value = shades.${shade};
            }) (builtins.attrNames shades)
          ) colorNames;
          colors = builtins.listToAttrs colorNameValuePairs;
        in
        lib.optionalAttrs (palette != null) (
          with colors;
          colors
          // rec {
            none = "NONE";
            background = neutral-950;
            foreground = neutral-50;

            regular-black = slate-900;
            regular-red = red-400;
            regular-green = green-400;
            regular-yellow = yellow-400;
            regular-blue = blue-400;
            regular-magenta = violet-400;
            regular-cyan = cyan-400;
            regular-white = slate-400;

            bright-black = slate-600;
            bright-red = red-200;
            bright-green = green-200;
            bright-yellow = yellow-200;
            bright-blue = blue-200;
            bright-magenta = violet-200;
            bright-cyan = cyan-200;
            bright-white = slate-50;

            bg-light = neutral-800;
            bg-base = neutral-900;
            bg-shade = background;

            fg-bright = foreground;
            fg-base = neutral-100;
            fg-dimmed = neutral-400;

            fg-inv = bg-base;
            bg-inv = fg-base;

            bg-selected = bg-inv;
            bg-success = regular-green;
            bg-disabled = bright-black;
            bg-error = regular-red;
            bg-warning = regular-yellow;
            bg-info = regular-blue;
            bg-hint = regular-black;

            fg-selected = fg-inv;
            fg-success = regular-black;
            fg-disabled = regular-black;
            fg-error = regular-black;
            fg-warning = regular-black;
            fg-info = regular-black;
            fg-hint = bright-white;

            fg-match = regular-magenta;
            fg-match-selected = regular-magenta;
          }
        );
    };
    fonts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            package = lib.mkOption {
              description = "font package";
              type = lib.types.str;
            };
            name = lib.mkOption {
              description = "font name";
              type = lib.types.str;
            };
          };
        }
      );
    };
  };
}
