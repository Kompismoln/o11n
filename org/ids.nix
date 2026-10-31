{
  config,
  lib,
  context,
  ...
}:
{
  options =
    let
      hex = lib.toLower (lib.toHexString config.int);
    in
    {
      int = lib.mkOption {
        description = "id";
        type = lib.types.int;
      };
      str = lib.mkOption {
        description = "id as string";
        type = lib.types.str;
        default = toString config.int;
        defaultText = lib.literalExpression "toString int";
      };
      hex = lib.mkOption {
        description = "id as hex";
        type = context.types.hextet;
        default = hex;
        defaultText = lib.literalExpression "lib.toLower (lib.toHexString int)";
      };
      hex4 = lib.mkOption {
        description = "id as hex with fixed length 4";
        type = context.types.hextetP4;
        default = lib.strings.fixedWidthString 4 "0" hex;
        defaultText = lib.literalExpression ''lib.fixedWidthString 4 "0" hex'';
      };
      hex8 = lib.mkOption {
        description = "id as hex with fixed length 8";
        type = context.types.hextetP8;
        default = lib.strings.fixedWidthString 8 "0" hex;
        defaultText = lib.literalExpression ''lib.fixedWidthString 8 "0" hex'';
      };
      hex32 = lib.mkOption {
        description = "id as hex with fixed length 32";
        type = context.types.hextetP32;
        default = lib.strings.fixedWidthString 32 "0" hex;
        defaultText = lib.literalExpression ''lib.fixedWidthString 32 "0" hex'';
      };
    };
}
