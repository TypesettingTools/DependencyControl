-- Bindings for the FreeType calls the text-extents backend measures with. Values are transcribed from
-- FreeType's freetype.h and tttables.h.

ffi = require "ffi"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"

msgs = {
  describeError: {
    described: "%s (error %d)"
    codeOnly: "error %d"
  }
}

-- FT_FaceRec and the two SFNT tables stop after the last field read here. FreeType allocates all of
-- them, so the tail these omit is never addressed and never sized, while the fields above it keep
-- their real offsets.
freetypeBinding = ffiBinding.bind {
  -- a runtime install carries only the versioned soname, so the bare name is the last thing to try
  library: {"libfreetype.so.6", "libfreetype.6.dylib", "freetype"}
  structs: {"FtGeneric", "FtBBox", "FtVector", "FtSizeMetrics", "FtSizeRec", "FtFaceRec",
    "TtHoriHeader", "TtOs2"}
  functions: {"FT_Init_FreeType", "FT_New_Face", "FT_Done_Face", "FT_Set_Pixel_Sizes",
    "FT_Get_Char_Index", "FT_Get_Advance", "FT_Get_Kerning", "FT_Get_Sfnt_Table", "FT_MulDiv",
    "FT_Error_String"}
  declarations: [[
    typedef struct { void* data; void* finalizer; } FtGeneric;
    typedef struct { long xMin; long yMin; long xMax; long yMax; } FtBBox;
    typedef struct { long x; long y; } FtVector;

    typedef struct {
      unsigned short x_ppem; unsigned short y_ppem;
      long x_scale; long y_scale;
      long ascender; long descender; long height; long max_advance;
    } FtSizeMetrics;

    typedef struct {
      void* face;
      FtGeneric generic;
      FtSizeMetrics metrics;
      void* internal;
    } FtSizeRec;

    typedef struct {
      long num_faces; long face_index; long face_flags; long style_flags; long num_glyphs;
      char* family_name; char* style_name;
      int num_fixed_sizes; void* available_sizes;
      int num_charmaps; void* charmaps;
      FtGeneric generic;
      FtBBox bbox;
      unsigned short units_per_EM;
      short ascender; short descender; short height;
      short max_advance_width; short max_advance_height;
      short underline_position; short underline_thickness;
      void* glyph;
      FtSizeRec* size;
      void* charmap;
    } FtFaceRec;

    typedef struct {
      long Version;
      short Ascender; short Descender; short Line_Gap;
      unsigned short advance_Width_Max;
      short min_Left_Side_Bearing; short min_Right_Side_Bearing; short xMax_Extent;
      short caret_Slope_Rise; short caret_Slope_Run; short caret_Offset;
      short Reserved[4];
      short metric_Data_Format;
      unsigned short number_Of_HMetrics;
    } TtHoriHeader;

    typedef struct {
      unsigned short version;
      short xAvgCharWidth;
      unsigned short usWeightClass; unsigned short usWidthClass; unsigned short fsType;
      short ySubscriptXSize; short ySubscriptYSize; short ySubscriptXOffset; short ySubscriptYOffset;
      short ySuperscriptXSize; short ySuperscriptYSize;
      short ySuperscriptXOffset; short ySuperscriptYOffset;
      short yStrikeoutSize; short yStrikeoutPosition; short sFamilyClass;
      unsigned char panose[10];
      unsigned long ulUnicodeRange1; unsigned long ulUnicodeRange2;
      unsigned long ulUnicodeRange3; unsigned long ulUnicodeRange4;
      signed char achVendID[4];
      unsigned short fsSelection; unsigned short usFirstCharIndex; unsigned short usLastCharIndex;
      short sTypoAscender; short sTypoDescender; short sTypoLineGap;
      unsigned short usWinAscent; unsigned short usWinDescent;
    } TtOs2;

    int FT_Init_FreeType(void** library);
    int FT_New_Face(void* library, const char* path, long faceIndex, FtFaceRec** face);
    int FT_Done_Face(FtFaceRec* face);
    int FT_Set_Pixel_Sizes(FtFaceRec* face, unsigned int width, unsigned int height);
    unsigned int FT_Get_Char_Index(FtFaceRec* face, unsigned long charCode);
    int FT_Get_Advance(FtFaceRec* face, unsigned int glyphIndex, int loadFlags, long* advance);
    int FT_Get_Kerning(FtFaceRec* face, unsigned int leftGlyph, unsigned int rightGlyph,
      unsigned int kerningMode, FtVector* kerning);
    void* FT_Get_Sfnt_Table(FtFaceRec* face, int tag);
    long FT_MulDiv(long a, long b, long c);
    const char* FT_Error_String(int errorCode);
  ]]
}

freetype = freetypeBinding.functions

-- Every call takes a library handle, so one that never initialized leaves the binding unusable and
-- `isAvailable` false. It is held for the process: faces are opened against it and read from it later.
initializeLibrary = ->
  return nil unless freetypeBinding.isAvailable
  handle = ffi.new "void*[1]"
  initialized, code = pcall freetype.FT_Init_FreeType, handle
  return initialized and code == 0 and handle[0] or nil

library = initializeLibrary!
isAvailable = library != nil

-- absent unless FreeType was built with FT_CONFIG_OPTION_ERROR_STRINGS, and it reports an unknown
-- code as a null pointer even then
hasErrorStrings = isAvailable and pcall -> freetype.FT_Error_String

FaceOut = ffi.typeof "#{freetypeBinding.prefixedNames.FtFaceRec}*[1]"
AdvanceOut = ffi.typeof "long[1]"
KerningOut = freetypeBinding.types.FtVector
HoriHeaderPointer = ffi.typeof "#{freetypeBinding.prefixedNames.TtHoriHeader}*"
Os2Pointer = ffi.typeof "#{freetypeBinding.prefixedNames.TtOs2}*"

---Which table FT_Get_Sfnt_Table hands back, for a face built from an SFNT font.
---@alias FreeTypeSfntTag
---| 0 # Head: the font header, holding the units per em among other things
---| 1 # Maxp: the resource limits a rasterizer needs to honor
---| 2 # Os2: the OS/2 and Windows metrics, which the Windows cell height comes from
---| 3 # Hhea: the horizontal header, holding the typographic line metrics
---| 4 # Vhea: the vertical header, for a face laid out in vertical lines
---| 5 # Post: the PostScript table, holding glyph names and the italic angle
---| 6 # Pclt: the PCL 5 table, which few faces still carry

---What a glyph-loading call should do with the glyph, and which parts of it to skip.
---@alias FreeTypeLoadFlag
---| 0 # Default: scale and hint the glyph, keeping its outline
---| 1 # NoScale: report the glyph in font units, leaving the face's current size out of it
---| 2 # NoHinting: scale the glyph without grid-fitting it
---| 4 # Render: rasterize the glyph into a bitmap after loading it
---| 8 # NoBitmap: ignore any embedded bitmap, loading the outline instead
---| 16 # VerticalLayout: report the metrics for vertical rather than horizontal layout
---| 32 # ForceAutohint: use FreeType's own hinter even where the face carries instructions
---| 64 # CropBitmap: trim an embedded bitmap's blank rows and columns
---| 128 # Pedantic: fail on a malformed instruction rather than working around it
---| 512 # IgnoreGlobalAdvanceWidth: take the advance from the glyph rather than the face
---| 1024 # NoRecurse: leave a composite glyph's components unloaded
---| 2048 # IgnoreTransform: ignore a transform set on the face
---| 4096 # Monochrome: rasterize without antialiasing, one bit per pixel
---| 8192 # LinearDesign: report the advances unscaled alongside the scaled ones
---| 16384 # SbitsOnly: load only an embedded bitmap, failing where there is none
---| 32768 # NoAutohint: never fall back to FreeType's own hinter
---| 1048576 # Color: load an embedded color bitmap or a color layer
---| 2097152 # ComputeMetrics: recompute the metrics from the outline rather than trusting the face
---| 4194304 # BitmapMetricsOnly: read an embedded bitmap's metrics without loading its pixels
---| 16777216 # NoSvg: ignore an OpenType SVG document for the glyph

---What units a kerning distance comes back in, and whether it is fitted to the pixel grid.
---@alias FreeTypeKerningMode
---| 0 # Default: scaled to the face's current size and grid-fitted, in 1/64th pixels
---| 1 # Unfitted: scaled to the current size without grid-fitting, in 1/64th pixels
---| 2 # Unscaled: in font units, leaving the face's current size out of it

---What a face is and what it carries, as reported by its `face_flags`.
---@alias FreeTypeFaceFlag
---| 1 # Scalable: describes its glyphs as outlines, so any size can be rendered
---| 2 # FixedSizes: carries embedded bitmaps at fixed sizes
---| 4 # FixedWidth: every glyph advances by the same width, as a monospaced face does
---| 8 # Sfnt: stored in the SFNT container, so the OS/2 and hhea tables are reachable
---| 16 # Horizontal: carries horizontal layout metrics
---| 32 # Vertical: carries vertical layout metrics as well
---| 64 # Kerning: carries a `kern` table, which is the only kerning FreeType reads
---| 128 # FastGlyphs: unused, retained from an earlier FreeType
---| 256 # MultipleMasters: a variable font, whose axes can be set to a design instance
---| 512 # GlyphNames: carries a name for each glyph
---| 1024 # ExternalStream: reads from a stream the caller owns rather than one FreeType opened
---| 2048 # Hinter: a hinter for this face's format is built into this FreeType
---| 4096 # CidKeyed: keyed by CID rather than by glyph name, as a CJK PostScript face is
---| 8192 # Tricky: needs its bytecode interpreted even at large sizes to render correctly
---| 16384 # Color: carries color glyphs, as a bitmap, a layered outline or SVG
---| 32768 # Variation: a variable font currently set to a non-default instance
---| 65536 # Svg: carries OpenType SVG documents for some glyphs
---| 131072 # Sbix: carries an Apple `sbix` color bitmap table
---| 262144 # SbixOverlay: its `sbix` bitmaps are drawn over the outline rather than instead of it

---FreeType's face, glyph-metric and SFNT-table calls.
---@class FfiFreeType
---@field isAvailable boolean Whether FreeType loaded and initialized; gate any use of the rest on it.
---@field freetype ffi.namespace* The loaded FreeType library, or nil where it couldn't be loaded.
---@field library ffi.cdata* The initialized FT_Library every call takes, nil while unavailable.
---@field FaceOut ffi.ctype* Constructor for the one-element array FT_New_Face writes the face into.
---@field AdvanceOut ffi.ctype* Constructor for the one-element array FT_Get_Advance writes into.
---@field KerningOut ffi.ctype* Constructor for the vector FT_Get_Kerning writes into.
---@field HoriHeaderPointer ffi.ctype* Cast for the hhea table FT_Get_Sfnt_Table returns.
---@field Os2Pointer ffi.ctype* Cast for the OS/2 table FT_Get_Sfnt_Table returns.
---@field SfntTag table<string, FreeTypeSfntTag> SFNT table selectors, keyed by name.
---@field LoadFlag table<string, FreeTypeLoadFlag> Glyph-loading flags, keyed by name.
---@field KerningMode table<string, FreeTypeKerningMode> Kerning units, keyed by name.
---@field FaceFlag table<string, FreeTypeFaceFlag> Face capability bits, keyed by name.
---@field NO_OS2_TABLE_VERSION integer The version an OS/2 table reports when the face carries none.
local FreeType
FreeType = {
  ---@type boolean
  isAvailable: isAvailable

  ---@type ffi.namespace*
  freetype: isAvailable and freetype or nil

  ---@type ffi.cdata*
  library: library

  ---@type ffi.ctype*
  FaceOut: FaceOut

  ---@type ffi.ctype*
  AdvanceOut: AdvanceOut

  ---@type ffi.ctype*
  KerningOut: KerningOut

  ---@type ffi.ctype*
  HoriHeaderPointer: HoriHeaderPointer

  ---@type ffi.ctype*
  Os2Pointer: Os2Pointer

  ---FreeType fabricates an OS/2 table for a face that has none and marks it with this version.
  ---@type integer
  NO_OS2_TABLE_VERSION: 0xFFFF

  ---Returns FreeType's own wording for an error code, or the bare code where it has none.
  ---@param code integer The code a FreeType call returned.
  ---@return string described The wording plus the numeric code, or the code alone.
  describeError: (code) ->
    described = hasErrorStrings and freetype.FT_Error_String code
    return msgs.describeError.codeOnly\format code unless described != nil and described != false
    return msgs.describeError.described\format ffi.string(described), code

  SfntTag: {
    Head: 0
    Maxp: 1
    Os2: 2
    Hhea: 3
    Vhea: 4
    Post: 5
    Pclt: 6
  }

  LoadFlag: {
    Default: 0
    NoScale: 0x1
    NoHinting: 0x2
    Render: 0x4
    NoBitmap: 0x8
    VerticalLayout: 0x10
    ForceAutohint: 0x20
    CropBitmap: 0x40
    Pedantic: 0x80
    IgnoreGlobalAdvanceWidth: 0x200
    NoRecurse: 0x400
    IgnoreTransform: 0x800
    Monochrome: 0x1000
    LinearDesign: 0x2000
    SbitsOnly: 0x4000
    NoAutohint: 0x8000
    Color: 0x100000
    ComputeMetrics: 0x200000
    BitmapMetricsOnly: 0x400000
    NoSvg: 0x1000000
  }

  KerningMode: {
    Default: 0
    Unfitted: 1
    Unscaled: 2
  }

  FaceFlag: {
    Scalable: 0x1
    FixedSizes: 0x2
    FixedWidth: 0x4
    Sfnt: 0x8
    Horizontal: 0x10
    Vertical: 0x20
    Kerning: 0x40
    FastGlyphs: 0x80
    MultipleMasters: 0x100
    GlyphNames: 0x200
    ExternalStream: 0x400
    Hinter: 0x800
    CidKeyed: 0x1000
    Tricky: 0x2000
    Color: 0x4000
    Variation: 0x8000
    Svg: 0x10000
    Sbix: 0x20000
    SbixOverlay: 0x40000
  }
}

return FreeType
