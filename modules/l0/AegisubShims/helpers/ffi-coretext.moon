-- Values are transcribed from the CoreText and CFString framework headers.

ffi = require "ffi"
Enum = require "l0.DependencyControl.Enum"
Flags = require "l0.DependencyControl.Flags"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"

-- CFIndex is a long, which matches the 64-bit long of every platform a Mac framework can load on;
-- CGFloat is a double there for the same reason. CFStringRef, CTFontRef and CFDataRef pass as plain
-- pointers, since nothing here reaches into them.
coreFoundationBinding = ffiBinding.bind {
  library: "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
  functions: {"CFStringCreateWithBytes", "CFStringGetCString", "CFRelease", "CFDataGetLength",
    "CFDataGetBytePtr", "CFDictionaryCreate", "CFDictionaryGetValue", "CFAttributedStringCreate",
    "CFNumberCreate", "CFNumberGetValue"}
  variables: {"kCFTypeDictionaryKeyCallBacks", "kCFTypeDictionaryValueCallBacks"}
  declarations: [[
    void* CFStringCreateWithBytes(void* allocator, const char* bytes, long numBytes, uint32_t encoding, unsigned char isExternalRepresentation);
    unsigned char CFStringGetCString(void* theString, char* buffer, long bufferSize, uint32_t encoding);
    void CFRelease(void* cf);
    long CFDataGetLength(void* theData);
    const uint8_t* CFDataGetBytePtr(void* theData);
    void* CFDictionaryCreate(void* allocator, const void** keys, const void** values, long numValues, const void* keyCallBacks, const void* valueCallBacks);
    void* CFAttributedStringCreate(void* allocator, void* str, void* attributes);
    const void* CFDictionaryGetValue(void* theDict, const void* key);
    void* CFNumberCreate(void* allocator, long theType, const void* valuePtr);
    unsigned char CFNumberGetValue(void* number, long theType, void* valuePtr);

    /* The retain/release callback sets a dictionary of CoreFoundation objects is built with. Only
       their addresses are ever passed on, so each is declared as a byte array that decays to one;
       reading the struct itself would need its layout, and nothing here looks inside. */
    extern const uint8_t kCFTypeDictionaryKeyCallBacks[64];
    extern const uint8_t kCFTypeDictionaryValueCallBacks[64];
  ]]
}

coreTextBinding = ffiBinding.bind {
  library: "/System/Library/Frameworks/CoreText.framework/CoreText"
  structs: {"CgSize", "CgAffineTransform"}
  functions: {"CTFontCreateWithName", "CTFontCopyTable", "CTFontCopyPostScriptName",
    "CTFontDescriptorCreateWithAttributes", "CTFontDescriptorCopyAttribute",
    "CTFontCreateWithFontDescriptor",
    "CTFontGetUnitsPerEm", "CTFontGetGlyphsForCharacters", "CTFontGetAdvancesForGlyphs",
    "CTLineCreateWithAttributedString", "CTLineGetTypographicBounds"}
  variables: {"kCTFontAttributeName", "kCTFontFamilyNameAttribute", "kCTFontSizeAttribute",
    "kCTFontTraitsAttribute", "kCTFontSymbolicTrait", "kCTFontWeightTrait", "kCTFontWidthTrait",
    "kCTFontSlantTrait"}
  declarations: [[
    typedef struct { double width; double height; } CgSize;

    typedef struct { double a; double b; double c; double d; double tx; double ty; } CgAffineTransform;

    void* CTFontCreateWithName(void* name, double size, const void* matrix);
    void* CTFontCopyTable(void* font, uint32_t table, uint32_t options);

    /* names the face a request actually matched, which two spellings of the same request need not
       agree on even when their advances do */
    void* CTFontCopyPostScriptName(void* font);

    /* wxOSX states the whole request as attributes and matches that one descriptor, so the family
       name, the italic bit and the numeric weight and width all take part in choosing the cut */
    void* CTFontDescriptorCreateWithAttributes(void* attributes);
    void* CTFontDescriptorCopyAttribute(void* descriptor, void* attribute);
    void* CTFontCreateWithFontDescriptor(void* descriptor, double size, const CgAffineTransform* matrix);
    unsigned int CTFontGetUnitsPerEm(void* font);
    unsigned char CTFontGetGlyphsForCharacters(void* font, const uint16_t* characters, uint16_t* glyphs, long count);
    double CTFontGetAdvancesForGlyphs(void* font, uint32_t orientation, const uint16_t* glyphs, CgSize* advances, long count);

    /* laying a run out the way wxOSX measures it, so the platform's own kerning and per-character
       fallback are in the numbers rather than derived around */
    void* CTLineCreateWithAttributedString(void* attrString);
    double CTLineGetTypographicBounds(void* line, double* ascent, double* descent, double* leading);

    /* the attribute a CFAttributedString names its font under, the three a descriptor states a font
       request through, and the traits inside the third of those */
    extern void* const kCTFontAttributeName;
    extern void* const kCTFontFamilyNameAttribute;
    extern void* const kCTFontSizeAttribute;
    extern void* const kCTFontTraitsAttribute;
    extern void* const kCTFontSymbolicTrait;
    extern void* const kCTFontWeightTrait;
    extern void* const kCTFontWidthTrait;
    extern void* const kCTFontSlantTrait;
  ]]
}

isAvailable = coreFoundationBinding.isAvailable and coreTextBinding.isAvailable

---Builds the numeric four-character code a font table is asked for by.
---@param tag string The four-character table name, "OS/2" and the like.
---@return integer code The big-endian packing CTFontCopyTable takes.
fourCharCode = (tag) ->
  first, second, third, fourth = tag\byte 1, 4
  return first * 0x1000000 + second * 0x10000 + third * 0x100 + fourth

---How CoreFoundation should store or read the number it was handed.
---@alias CoreFoundationNumberType
---| 9 # Int: kCFNumberIntType, a plain C int
---| 13 # Double: kCFNumberDoubleType, which CGFloat is on every platform a Mac framework loads on
---| 16 # CgFloat: kCFNumberCGFloatType, the type a trait value is stated in

---The string encoding a CFString is created from.
---@alias CoreFoundationStringEncoding
---| 134217984 # Utf8: kCFStringEncodingUTF8

---Which advance a glyph is measured by.
---@alias CoreTextFontOrientation
---| 0 # Default: the font's own layout direction, horizontal for every face measured here
---| 1 # Horizontal
---| 2 # Vertical

---The SFNT tables the text-extents derivation reads, as four-character codes.
---@alias CoreTextTableTag
---| 1330851634 # Os2: the OS/2 and Windows metrics table
---| 1751672161 # HoriHeader: hhea, the horizontal header holding the typographic line metrics
---| 1128678944 # Cff: the PostScript outlines, whose presence is what GDI reads no line gap off

StringEncoding = Enum "CoreFoundationStringEncoding", {
  Utf8: 0x08000100
}

NumberType = Enum "CoreFoundationNumberType", {
  Int: 9
  Double: 13
  CgFloat: 16
}

-- A descriptor states every trait a face has at once, so these combine rather than one being picked.
---@alias CoreTextFontTrait integer A combination of FontTrait members.
FontTrait = Flags "CoreTextFontTrait", {
  Italic: 1 -- an italic or oblique cut
  Bold: 2 -- a bold cut
}

---The normalized weight a descriptor states through `kCTFontWeightTrait`, on the scale running from
---thinnest at -1 to heaviest at 1. Any value on that scale is matchable; these are the ones the system
---names, published as the `NSFontWeight` constants.
---@alias CoreTextFontWeight
---| -0.8 # UltraLight
---| -0.6 # Thin
---| -0.4 # Light
---| 0.0 # Regular: the weight a face gets for stating none
---| 0.23 # Medium
---| 0.3 # Semibold
---| 0.4 # Bold
---| 0.56 # Heavy
---| 0.62 # Black
FontWeight = Enum "CoreTextFontWeight", {
  UltraLight: -0.8
  Thin: -0.6
  Light: -0.4
  Regular: 0.0
  Medium: 0.23
  Semibold: 0.3
  Bold: 0.4
  Heavy: 0.56
  Black: 0.62
}

---The normalized width a descriptor states through `kCTFontWidthTrait`, on the scale running from
---narrowest at -1 to widest at 1. The system names only the middle of it.
---@alias CoreTextFontWidth
---| 0.0 # Regular: the width a face gets for stating none
FontWidth = Enum "CoreTextFontWidth", {
  Regular: 0.0
}

FontOrientation = Enum "CoreTextFontOrientation", {
  Default: 0
  Horizontal: 1
  Vertical: 2
}

TableTag = Enum "CoreTextTableTag", {
  Os2: fourCharCode "OS/2"
  HoriHeader: fourCharCode "hhea"
  Cff: fourCharCode "CFF "
}

---CoreText's font and glyph-metric calls, with the CoreFoundation pieces they hand back and forth,
---as the text-extents backend measures with them. Both frameworks exist only on macOS, so
---`isAvailable` is false everywhere else.
---@class FfiCoreText
---@field isAvailable boolean Whether both frameworks loaded, false anywhere but macOS.
---@field coreFoundation table<string, ffi.cdata*> The bound CoreFoundation calls, nil while unavailable.
---@field coreText table<string, ffi.cdata*> The bound CoreText calls, nil while unavailable.
---@field coreFoundationSymbols table<string, any> The bound CoreFoundation data symbols, nil while unavailable.
---@field coreTextSymbols table<string, any> The bound CoreText data symbols, nil while unavailable.
---@field CgSize ffi.ctype* Constructor for the CGSize array the advance call fills in.
---@field CgAffineTransform ffi.ctype* Constructor for the matrix a synthesized slant is applied through.
---@field NumberType Enum How CFNumberGetValue reads a number, as a CoreFoundationNumberType enum.
---@field StringEncoding Enum The string encodings, as a CoreFoundationStringEncoding enum.
---@field FontTrait Flags Symbolic font traits, as a CoreTextFontTrait flag set.
---@field FontWeight Enum The named normalized weights, as a CoreTextFontWeight enum.
---@field FontWidth Enum The named normalized widths, as a CoreTextFontWidth enum.
---@field FontOrientation Enum The advance orientations, as a CoreTextFontOrientation enum.
---@field TableTag Enum The font table codes, as a CoreTextTableTag enum.
return {
  ---@type boolean
  isAvailable: isAvailable

  ---@type table<string, ffi.cdata*>
  coreFoundation: coreFoundationBinding.functions

  ---@type table<string, ffi.cdata*>
  coreText: coreTextBinding.functions

  ---@type table<string, any>
  coreFoundationSymbols: coreFoundationBinding.variables

  ---@type table<string, any>
  coreTextSymbols: coreTextBinding.variables

  ---@type ffi.ctype*
  CgSize: coreTextBinding.types.CgSize

  ---@type ffi.ctype*
  CgAffineTransform: coreTextBinding.types.CgAffineTransform

  StringEncoding: StringEncoding
  NumberType: NumberType
  FontOrientation: FontOrientation
  TableTag: TableTag

  FontTrait: FontTrait
  FontWeight: FontWeight
  FontWidth: FontWidth
}
