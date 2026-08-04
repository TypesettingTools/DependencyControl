-- Bindings for the fontconfig calls that resolve a family name to a font file. Values are transcribed
-- from fontconfig's fontconfig.h.

ffi = require "ffi"
Enum = require "l0.DependencyControl.Enum"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"

-- fontconfig's own FcChar8 is an unsigned char, declared here as a plain char so a Lua string converts
-- straight into the string parameters and ffi.string reads the results back
fontconfigBinding = ffiBinding.bind {
  -- a runtime install carries only the versioned soname, so the bare name is the last thing to try
  library: {"libfontconfig.so.1", "libfontconfig.1.dylib", "fontconfig"}
  structs: {"FcPattern"}
  functions: {"FcInit", "FcPatternCreate", "FcPatternDestroy", "FcPatternAddString",
    "FcPatternAddInteger", "FcPatternGetString", "FcPatternGetInteger", "FcConfigSubstitute",
    "FcDefaultSubstitute", "FcFontMatch"}
  declarations: [[
    typedef struct FcPattern FcPattern;

    int FcInit(void);
    FcPattern* FcPatternCreate(void);
    void FcPatternDestroy(FcPattern* pattern);
    int FcPatternAddString(FcPattern* pattern, const char* object, const char* value);
    int FcPatternAddInteger(FcPattern* pattern, const char* object, int value);
    int FcPatternGetString(const FcPattern* pattern, const char* object, int index, char** value);
    int FcPatternGetInteger(const FcPattern* pattern, const char* object, int index, int* value);
    int FcConfigSubstitute(void* config, FcPattern* pattern, int kind);
    void FcDefaultSubstitute(FcPattern* pattern);
    FcPattern* FcFontMatch(void* config, FcPattern* pattern, int* result);
  ]]
}

fontconfig = fontconfigBinding.functions

-- Loading the font directories is what makes a match possible at all, so a failure here leaves the
-- binding unusable rather than merely slow. The config it builds is the process-wide current one,
-- which every call below reaches by passing a null config.
initialize = ->
  return false unless fontconfigBinding.isAvailable
  initialized, result = pcall fontconfig.FcInit
  return initialized and result != 0

isAvailable = initialize!

StringOut = ffi.typeof "char*[1]"
IntegerOut = ffi.typeof "int[1]"

---How heavy a face's strokes are, on fontconfig's own scale rather than the OpenType one.
---@alias FontconfigWeight
---| 0 # Thin: the lightest weight on the scale
---| 40 # ExtraLight: also called "UltraLight"
---| 50 # Light
---| 55 # DemiLight: also called "SemiLight"
---| 75 # Book: lighter than Regular, which some families ship as their upright weight
---| 80 # Regular: the upright weight of a normal face, also called "Normal"
---| 100 # Medium
---| 180 # DemiBold: also called "SemiBold"
---| 200 # Bold: what an ASS style's bold flag asks for
---| 205 # ExtraBold: also called "UltraBold"
---| 210 # Black: the darkest weight in common use, also called "Heavy"
---| 215 # ExtraBlack: also called "UltraBlack"

---How far a face's glyphs lean.
---@alias FontconfigSlant
---| 0 # Roman: upright
---| 100 # Italic: a drawn italic cut, whose letterforms differ from the upright
---| 110 # Oblique: an upright face sheared, without redrawn letterforms

---Which stage of matching a substitution pass applies to.
---@alias FontconfigMatchKind
---| 0 # Pattern: edits the request before matching, applying the user's font preferences
---| 1 # Font: edits the matched font afterwards, applying per-font rendering settings
---| 2 # Scan: edits a font's properties as it is added to the font set

---Whether a value could be read out of a pattern.
---@alias FontconfigResult
---| 0 # Match: the object was present and had the requested type
---| 1 # NoMatch: the pattern carries no such object
---| 2 # TypeMismatch: the object is present but holds a different type
---| 3 # NoId: the object is present but has no value at the requested index
---| 4 # OutOfMemory: the allocation needed to answer failed

---The pattern properties this binding reads and writes, by their fontconfig names.
---@alias FontconfigProperty
---| "family" # Family: the family name, which is what an ASS style names
---| "style" # Style: the style name within the family, such as "Bold Italic"
---| "slant" # Slant: how far the face leans, as a FontconfigSlant
---| "weight" # Weight: how heavy the strokes are, as a FontconfigWeight
---| "size" # Size: the point size the font is wanted at
---| "pixelsize" # PixelSize: the pixel size the font is wanted at
---| "file" # File: path to the file holding the face, which a match reports
---| "index" # Index: the face's index within that file, which a match reports
---| "fullname" # FullName: the face's full human-readable name
---| "scalable" # Scalable: whether the face can be rendered at any size
---| "outline" # Outline: whether the face is described by outlines rather than bitmaps

---Fontconfig's pattern-matching calls, which resolve a family name to a font file.
Property = Enum "FontconfigProperty", {
  Family: "family"
  Style: "style"
  Slant: "slant"
  Weight: "weight"
  Size: "size"
  PixelSize: "pixelsize"
  File: "file"
  Index: "index"
  FullName: "fullname"
  Scalable: "scalable"
  Outline: "outline"
}

Weight = Enum "FontconfigWeight", {
  Thin: 0
  ExtraLight: 40
  Light: 50
  DemiLight: 55
  Book: 75
  Regular: 80
  Medium: 100
  DemiBold: 180
  Bold: 200
  ExtraBold: 205
  Black: 210
  ExtraBlack: 215
}

Slant = Enum "FontconfigSlant", {
  Roman: 0
  Italic: 100
  Oblique: 110
}

MatchKind = Enum "FontconfigMatchKind", {
  Pattern: 0
  Font: 1
  Scan: 2
}

Result = Enum "FontconfigResult", {
  Match: 0
  NoMatch: 1
  TypeMismatch: 2
  NoId: 3
  OutOfMemory: 4
}

---@class FfiFontconfig
---@field isAvailable boolean Whether fontconfig loaded and initialized; gate any use of the rest on it.
---@field fontconfig ffi.namespace* The loaded fontconfig library, or nil where it couldn't be loaded.
---@field StringOut ffi.ctype* Constructor for the one-element array FcPatternGetString writes into.
---@field IntegerOut ffi.ctype* Constructor for the one-element array the integer getters write into.
---@field Property Enum The pattern property names, as a FontconfigProperty enum.
---@field Weight Enum The weights, as a FontconfigWeight enum.
---@field Slant Enum The slants, as a FontconfigSlant enum.
---@field MatchKind Enum The substitution stages, as a FontconfigMatchKind enum.
---@field Result Enum The value-lookup outcomes, as a FontconfigResult enum.
return {
  ---@type boolean
  isAvailable: isAvailable

  ---@type ffi.namespace*
  fontconfig: isAvailable and fontconfig or nil

  ---@type ffi.ctype*
  StringOut: StringOut

  ---@type ffi.ctype*
  IntegerOut: IntegerOut

  Property: Property
  Weight: Weight
  Slant: Slant
  MatchKind: MatchKind
  Result: Result
}
