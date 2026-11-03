# Usage: import ./dev/index.nix { lib; src; parts; }, as flake.nix's index does: what o11n-dev index
# writes docs/index/<part>.md from: the options of an org, as org/context.nix
# declares it, evaluated for an inventory that holds nothing, each under the part whose code
# declares it.
# Policy: a default computed from an entity's own config, which a <name> placeholder has none of,
# has a defaultText, or the index fails to evaluate.
# Policy: a module mounted in more than one place, as org/entity.nix is in each class, is indexed
# once, as a type named by its file, `<entity>`, and where it's mounted says so; its options are
# to read alike wherever it's mounted, or the index fails to evaluate.
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
      "${src}/org/context.nix"
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
        loc = lib.tail option.loc;
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

  indexed = builtins.filter (
    option: option.files != [ ] && partOf (builtins.head option.files) != null
  ) options;

  key = lib.concatStringsSep ".";
  file = option: builtins.head option.files;
  byLoc = lib.listToAttrs (map (option: lib.nameValuePair (key option.loc) option) indexed);

  withoutNames =
    loc: if loc != [ ] && lib.last loc == "<name>" then withoutNames (lib.init loc) else loc;

  mount =
    option:
    let
      up =
        loc:
        let
          above = withoutNames (lib.init loc);
          declared = byLoc.${key above} or null;
        in
        if above != [ ] && declared != null && file declared == file option then up above else lib.init loc;
    in
    up option.loc;

  within = option: lib.drop (builtins.length (mount option)) option.loc;

  mounts = lib.groupBy file indexed;
  shared = builtins.filter (
    file: builtins.length (lib.unique (map (option: key (mount option)) mounts.${file})) > 1
  ) (builtins.attrNames mounts);
  isShared = option: builtins.elem (file option) shared;
  typeName = file: "<${lib.removeSuffix ".nix" (baseNameOf file)}>";

  named =
    loc:
    let
      declared = byLoc.${key loc} or null;
    in
    if declared != null && isShared declared then
      key ([ (typeName (file declared)) ] ++ within declared)
    else
      key loc;

  mountedAt =
    loc: lib.filter (file: builtins.any (option: mount option == loc) mounts.${file}) shared;

  # Policy: a submodule that is types, or types and options of its own, says which.
  typed =
    option:
    let
      loc =
        if option.type == null then
          [ ]
        else
          option.loc ++ lib.optional (lib.hasPrefix "attribute set of" option.type) "<name>";
      types = mountedAt loc;
      own = builtins.any (other: !isShared other && mount other == loc) indexed;
      said =
        lib.concatMapStringsSep ", " (file: "`${typeName file}`") types
        + lib.optionalString own " and its own options";
    in
    if types == [ ] then
      option
    else
      option
      // {
        type =
          if option.type == "submodule" then
            said
          else
            lib.replaceStrings [ "(submodule)" ] [ "(${said})" ] option.type;
      };

  entries = map typed indexed;

  inOptions = map (
    option:
    option
    // {
      section = "Options";
      name = key option.loc;
    }
  ) (builtins.filter (option: !isShared option) entries);

  inTypes = lib.concatMap (
    file:
    let
      own = builtins.filter (option: builtins.head option.files == file) entries;
      byWithin = lib.groupBy (option: key (within option)) own;
      alike =
        name: options:
        let
          read = option: {
            inherit (option)
              type
              description
              default
              prose
              ;
          };
          first = builtins.head options;
        in
        lib.throwIfNot (builtins.all (option: read option == read first) options)
          "dev/index.nix: ${typeName file}.${name} reads otherwise where it's mounted: ${
            lib.concatMapStringsSep ", " (option: key option.loc) options
          }; give it a defaultText or description that reads alike"
          (
            first
            // {
              section = "Types";
              name = "${typeName file}.${name}";
            }
          );
    in
    [
      {
        section = "Types";
        name = typeName file;
        type = null;
        default = null;
        prose = false;
        description = "had by ${
          lib.concatMapStringsSep ", " (loc: "`${loc}`") (lib.unique (map (option: named (mount option)) own))
        }";
        files = [ file ];
      }
    ]
    ++ lib.mapAttrsToList alike byWithin
  ) shared;

  order = option: "${option.section}\t${option.name}";
in
lib.mapAttrs (
  _: entries: map (option: removeAttrs option [ "loc" ]) (lib.sort (a: b: order a < order b) entries)
) (lib.groupBy (option: toString (partOf (builtins.head option.files))) (inOptions ++ inTypes))
