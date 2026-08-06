-- Bindings for the CoreText and CoreFoundation calls the text-extents backend measures with on macOS.
-- Values are transcribed from the CoreText and CFString framework headers. Both libraries load only
-- there, so `isAvailable` is false everywhere else.

ffi = require "ffi"
Enum = require "l0.DependencyControl.Enum"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"

-- CFIndex is a long, which matches the 64-bit long of every platform a Mac framework can load on;
-- CGFloat is a double there for the same reason. CFStringRef, CTFontRef and CFDataRef pass as plain
-- pointers, since nothing here reaches into them.
coreFoundationBinding = ffiBinding.bind {
  library: "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
  functions: {"CFStringCreateWithBytes", "CFRelease", "CFDataGetLength", "CFDataGetBytePtr"}
  declarations: [[
    void* CFStringCreateWithBytes(void* allocator, const char* bytes, long numBytes, uint32_t encoding, unsigned char isExternalRepresentation);
    void CFRelease(void* cf);
    long CFDataGetLength(void* theData);
    const uint8_t* CFDataGetBytePtr(void* theData);
  ]]
}

coreTextBinding = ffiBinding.bind {
  library: "/System/Library/Frameworks/CoreText.framework/CoreText"
  structs: {"CgSize"}
  functions: {"CTFontCreateWithName", "CTFontCreateCopyWithSymbolicTraits", "CTFontCopyTable",
    "CTFontGetUnitsPerEm", "CTFontGetGlyphsForCharacters", "CTFontGetAdvancesForGlyphs"}
  declarations: [[
    typedef struct { double width; double height; } CgSize;

    void* CTFontCreateWithName(void* name, double size, const void* matrix);
    void* CTFontCreateCopyWithSymbolicTraits(void* font, double size, const void* matrix, uint32_t symTraitValue, uint32_t symTraitMask);
    void* CTFontCopyTable(void* font, uint32_t table, uint32_t options);
    unsigned int CTFontGetUnitsPerEm(void* font);
    unsigned char CTFontGetGlyphsForCharacters(void* font, const uint16_t* characters, uint16_t* glyphs, long count);
    double CTFontGetAdvancesForGlyphs(void* font, uint32_t orientation, const uint16_t* glyphs, CgSize* advances, long count);
  ]]
}

isAvailable = coreFoundationBinding.isAvailable and coreTextBinding.isAvailable

---Builds the numeric four-character code a font table is asked for by.
---@param tag string The four-character table name, "OS/2" and the like.
---@return integer code The big-endian packing CTFontCopyTable takes.
fourCharCode = (tag) ->
  first, second, third, fourth = tag\byte 1, 4
  return first * 0x1000000 + second * 0x10000 + third * 0x100 + fourth

---The string encoding a CFString is created from.
---@alias CoreFoundationStringEncoding
---| 134217984 # Utf8: kCFStringEncodingUTF8

---Style attributes the font system matches and synthesizes on, combined as a bit set.
---@alias CoreTextFontTrait
---| 1 # Italic: an italic or oblique cut
---| 2 # Bold: a bold cut

---Which advance a glyph is measured by.
---@alias CoreTextFontOrientation
---| 0 # Default: the font's own layout direction, horizontal for every face measured here
---| 1 # Horizontal
---| 2 # Vertical

---The SFNT tables the text-extents derivation reads, as four-character codes.
---@alias CoreTextTableTag
---| 1330851634 # Os2: the OS/2 and Windows metrics table
---| 1751672161 # HoriHeader: hhea, the horizontal header carrying the typographic line metrics

StringEncoding = Enum "CoreFoundationStringEncoding", {
  Utf8: 0x08000100
}

FontOrientation = Enum "CoreTextFontOrientation", {
  Default: 0
  Horizontal: 1
  Vertical: 2
}

TableTag = Enum "CoreTextTableTag", {
  Os2: fourCharCode "OS/2"
  HoriHeader: fourCharCode "hhea"
}

---CoreText's font and glyph-metric calls, with the CoreFoundation pieces they hand back and forth.
---@class FfiCoreText
---@field isAvailable boolean Whether both frameworks loaded, false anywhere but macOS.
---@field coreFoundation table<string, ffi.cdata*> The bound CoreFoundation calls, nil while unavailable.
---@field coreText table<string, ffi.cdata*> The bound CoreText calls, nil while unavailable.
---@field CgSize ffi.ctype* Constructor for the CGSize array the advance call fills in.
---@field StringEncoding Enum The string encodings, as a CoreFoundationStringEncoding enum.
---@field FontTrait table<string, CoreTextFontTrait> Symbolic font traits, keyed by name.
---@field FontOrientation Enum The advance orientations, as a CoreTextFontOrientation enum.
---@field TableTag Enum The font table codes, as a CoreTextTableTag enum.
return {
  ---@type boolean
  isAvailable: isAvailable

  ---@type table<string, ffi.cdata*>
  coreFoundation: coreFoundationBinding.functions

  ---@type table<string, ffi.cdata*>
  coreText: coreTextBinding.functions

  ---@type ffi.ctype*
  CgSize: coreTextBinding.types.CgSize

  StringEncoding: StringEncoding
  FontOrientation: FontOrientation
  TableTag: TableTag

  -- a descriptor carries the traits a face has, so a caller combines these rather than picking one
  FontTrait: {
    Italic: 1
    Bold: 2
  }
}
