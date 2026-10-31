# Usage: import ./dev/index.nix { lib; src; parts; }, as flake.nix's index does: what dev/index.py
# writes docs/index/<part>.md from: the options of an org, as lib/context.nix
# declares it, evaluated for an inventory that holds nothing, each under the part whose code
# declares it.
# Policy: a default computed from an entity's own config, which a <name> placeholder has none of,
# has a defaultText, or the index fails to evaluate.
{
  lib,
  src,
  parts,
}:
let
  path = "${src}/tests/inventories/base";
  evaluated = lib.evalModules {
    modules = [
      {
        config = {
          inherit path;
          flake = {
            outPath = path;
            inputs = { };
          };
        };
      }
      "${src}/lib/context.nix"
    ];
  };

  inSource = file: lib.hasPrefix "${toString src}/" (toString file);
  relative =
    file:
    let
      name = lib.removePrefix "${toString src}/" (toString file);
    in
    if builtins.readFileType file == "directory" then "${name}/default.nix" else name;

  holds = entry: file: file == entry || lib.hasPrefix "${lib.removeSuffix "/" entry}/" file;
  partOf =
    file:
    lib.findFirst (name: builtins.any (entry: holds entry file) (parts.${name}.code or [ ])) null (
      builtins.attrNames parts
    );

  options =
    map
      (option: {
        name = lib.removePrefix "org." option.name;
        type = option.type or null;
        description = option.description or null;
        default =
          if option ? default then
            lib.replaceStrings [ path (toString src) ] [ "<org>" "<o11n>" ] option.default.text
          else
            null;
        prose = (option.default._type or null) == "literalMD";
        files = map relative (builtins.filter inSource option.declarations);
      })
      (
        builtins.filter (
          option:
          option.visible
          && !option.internal
          && option.name != "org"
          && builtins.any inSource option.declarations
        ) (lib.optionAttrSetToDocList evaluated.options.org)
      );
in
lib.mapAttrs (_: entries: lib.sort (a: b: a.name < b.name) entries) (
  lib.groupBy (option: toString (partOf (builtins.head option.files))) (
    builtins.filter (option: option.files != [ ] && partOf (builtins.head option.files) != null) options
  )
)
