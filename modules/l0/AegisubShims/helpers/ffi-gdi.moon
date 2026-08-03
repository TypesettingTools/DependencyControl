-- Bindings for the GDI text-measurement calls, with the LOGFONTW constant groups spelled out. Values
-- are transcribed from the Windows SDK's wingdi.h.

ffi = require "ffi"
Enum = require "l0.DependencyControl.Enum"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"
{:WCHAR_SIZE} = require "l0.DependencyControl.helpers.ffi-windows"

gdi32Binding = ffiBinding.bind {
  library: "gdi32"
  structs: {"LogFontW", "Size", "TextMetricW"}
  functions: {"CreateCompatibleDC", "SetMapMode", "CreateFontIndirectW", "SelectObject",
    "GetTextExtentPoint32W", "GetTextMetricsW", "DeleteObject", "DeleteDC"}
  declarations: [[
    typedef struct {
      long lfHeight; long lfWidth; long lfEscapement; long lfOrientation; long lfWeight;
      uint8_t lfItalic; uint8_t lfUnderline; uint8_t lfStrikeOut; uint8_t lfCharSet;
      uint8_t lfOutPrecision; uint8_t lfClipPrecision; uint8_t lfQuality; uint8_t lfPitchAndFamily;
      wchar_t lfFaceName[32];
    } LogFontW;

    typedef struct { long cx; long cy; } Size;

    typedef struct {
      long tmHeight; long tmAscent; long tmDescent; long tmInternalLeading; long tmExternalLeading;
      long tmAveCharWidth; long tmMaxCharWidth; long tmWeight; long tmOverhang;
      long tmDigitizedAspectX; long tmDigitizedAspectY;
      wchar_t tmFirstChar; wchar_t tmLastChar; wchar_t tmDefaultChar; wchar_t tmBreakChar;
      uint8_t tmItalic; uint8_t tmUnderlined; uint8_t tmStruckOut; uint8_t tmPitchAndFamily;
      uint8_t tmCharSet;
    } TextMetricW;

    void* CreateCompatibleDC(void* hdc);
    int SetMapMode(void* hdc, int mode);
    void* CreateFontIndirectW(const LogFontW* logFont);
    void* SelectObject(void* hdc, void* object);
    int GetTextExtentPoint32W(void* hdc, const wchar_t* text, int length, Size* size);
    int GetTextMetricsW(void* hdc, TextMetricW* metrics);
    int DeleteObject(void* object);
    int DeleteDC(void* hdc);
  ]]
}

isAvailable, gdi32 = gdi32Binding.isAvailable, gdi32Binding.functions
{LogFontW: LogFontW, Size: Size, TextMetricW: TextMetricW} = gdi32Binding.types

---How a device context maps logical units onto device units.
---@alias GdiMapMode
---| 1 # Text: one logical unit per device pixel, with y increasing downward
---| 2 # LoMetric: 0.1mm per unit, with y increasing upward
---| 3 # HiMetric: 0.01mm per unit
---| 4 # LoEnglish: 0.01 inch per unit
---| 5 # HiEnglish: 0.001 inch per unit
---| 6 # Twips: 1/1440 inch per unit, the unit typography measures points in
---| 7 # Isotropic: units the caller sets, with both axes forced to the same scale
---| 8 # Anisotropic: units the caller sets, with the axes scaled independently

---Stroke thickness a font is requested at. The mapper picks the nearest weight the face actually
---provides, so a value between two of these does not fail.
---@alias GdiFontWeight
---| 0 # DontCare: leaves the weight to the font mapper
---| 100 # Thin: the lightest weight on the scale
---| 200 # ExtraLight: also called "UltraLight"
---| 300 # Light
---| 400 # Normal: the upright weight of a regular face, also called "Regular"
---| 500 # Medium
---| 600 # SemiBold: also called "DemiBold"
---| 700 # Bold: what an ASS style's bold flag asks for
---| 800 # ExtraBold: also called "UltraBold"
---| 900 # Heavy: the darkest weight on the scale, also called "Black"

---Which font technology the mapper should prefer, and how exactly the realized font has to match the
---requested height, width, orientation and pitch. It disambiguates faces sharing one name, a raster and
---a TrueType cut of it for instance, so it is orthogonal to the typographic look GdiFontFamily picks
---among. The name is historical, from when a raster face could not be scaled to an arbitrary size.
---@alias GdiOutputPrecision
---| 0 # Default: the mapper's own behavior
---| 1 # String: not consulted by the mapper, but reported when raster faces are enumerated
---| 2 # Character: unused
---| 3 # Stroke: not consulted by the mapper, but reported when outline and vector faces are enumerated
---| 4 # TrueType: prefers a TrueType face where several installed faces share the requested name
---| 5 # Device: prefers a face the device supplies where several share the name
---| 6 # Raster: prefers a raster face where several share the name
---| 7 # TrueTypeOnly: refuses anything but TrueType, reverting to default behavior where none is installed
---| 8 # Outline: refuses anything but TrueType and other outline formats
---| 9 # ScreenOutline: picks an outline face whose rasterization suits a screen
---| 10 # PostScriptOnly: refuses anything but PostScript, reverting to default behavior where none is installed

---How glyphs falling outside the clipping region are clipped. The first three are alternatives and the
---rest are flags to combine with one of them, so this is not an exclusive value domain.
---@alias GdiClipPrecision
---| 0 # Default: the mapper's own clipping behavior
---| 1 # Character: clips a glyph at its character cell
---| 2 # Stroke: not consulted by the mapper, but reported when a font is enumerated
---| 15 # Mask: spans the bits the three alternatives above occupy, but Windows documents it as unused
---| 16 # LeftHandedAngles: rotates every font by the coordinate system's handedness, not the device's
---| 32 # TrueTypeAlways: reserved by Windows
---| 64 # DisableFontAssociation: turns off the font association that substitutes for East Asian text
---| 128 # Embedded: allows a read-only font embedded in the document

---How much rendering fidelity may be traded for appearance. Measurement is unaffected, since the
---metrics come from the face rather than from rasterization.
---@alias GdiFontQuality
---| 0 # Default: appearance does not matter
---| 1 # Draft: appearance matters less than under Proof, and font scaling is allowed
---| 2 # Proof: character quality matters more than matching the requested size, and scaling is refused
---| 3 # NonAntialiased: never antialiased
---| 4 # Antialiased: antialiased where the face supports it and the size is neither tiny nor huge
---| 5 # ClearType: rendered with ClearType subpixel antialiasing
---| 6 # ClearTypeNatural: ClearType with the face's natural glyph widths rather than hinted ones

---Whether a face's characters share one advance width. Occupies the low two bits of lfPitchAndFamily,
---so it combines with a family.
---@alias GdiFontPitch
---| 0 # Default: leaves the pitch to the font mapper
---| 1 # Fixed: every character advances by the same width, as a monospaced face does
---| 2 # Variable: advance width differs per character, as a proportional face does

---The general look the font mapper matches against. It selects the face outright where no face name is
---given, since the mapper then takes the first font fitting the remaining attributes, and it steers the
---substitute where a requested name is unavailable. Occupies the high nibble of lfPitchAndFamily, so it
---combines with a pitch.
---@alias GdiFontFamily
---| 0 # DontCare: leaves the mapper unconstrained by family
---| 16 # Roman: variable stroke width with serifs, as Times New Roman has
---| 32 # Swiss: variable stroke width without serifs, as Arial has
---| 48 # Modern: constant stroke width, as Courier New has
---| 64 # Script: faces resembling handwriting
---| 80 # Decorative: novelty faces, Old English among them

---The character set a face is requested for, which the mapper matches on alongside pitch and family.
---An ASS style's `encoding` field carries one of these, so the code page each names is what a script
---author needs to map it.
---@alias GdiCharSet
---| 0 # Ansi: code page 1252, Western European
---| 1 # Default: resolved from the system locale, so it names a different code page per machine
---| 2 # Symbol: the face's own symbol encoding rather than a code page
---| 77 # Mac: the Macintosh Roman encoding
---| 128 # ShiftJis: code page 932, Japanese
---| 129 # Hangul: code page 949, Korean
---| 130 # Johab: code page 1361, Korean
---| 134 # Gb2312: code page 936, simplified Chinese
---| 136 # ChineseBig5: code page 950, traditional Chinese
---| 161 # Greek: code page 1253
---| 162 # Turkish: code page 1254
---| 163 # Vietnamese: code page 1258
---| 177 # Hebrew: code page 1255
---| 178 # Arabic: code page 1256
---| 186 # Baltic: code page 1257
---| 204 # Russian: code page 1251, Cyrillic
---| 222 # Thai: code page 874
---| 238 # EastEurope: code page 1250, Central European
---| 255 # Oem: whichever code page the system uses for OEM text

MapMode = Enum "GdiMapMode", {
  Text: 1
  LoMetric: 2
  HiMetric: 3
  LoEnglish: 4
  HiEnglish: 5
  Twips: 6
  Isotropic: 7
  Anisotropic: 8
}

FontWeight = Enum "GdiFontWeight", {
  DontCare: 0
  Thin: 100
  ExtraLight: 200
  Light: 300
  Normal: 400
  Medium: 500
  SemiBold: 600
  Bold: 700
  ExtraBold: 800
  Heavy: 900
}

OutputPrecision = Enum "GdiOutputPrecision", {
  Default: 0
  String: 1
  Character: 2
  Stroke: 3
  TrueType: 4
  Device: 5
  Raster: 6
  TrueTypeOnly: 7
  Outline: 8
  ScreenOutline: 9
  PostScriptOnly: 10
}

FontQuality = Enum "GdiFontQuality", {
  Default: 0
  Draft: 1
  Proof: 2
  NonAntialiased: 3
  Antialiased: 4
  ClearType: 5
  ClearTypeNatural: 6
}

FontPitch = Enum "GdiFontPitch", {
  Default: 0
  Fixed: 1
  Variable: 2
}

FontFamily = Enum "GdiFontFamily", {
  DontCare: 0x00
  Roman: 0x10
  Swiss: 0x20
  Modern: 0x30
  Script: 0x40
  Decorative: 0x50
}

CharSet = Enum "GdiCharSet", {
  Ansi: 0
  Default: 1
  Symbol: 2
  Mac: 77
  ShiftJis: 128
  Hangul: 129
  Johab: 130
  Gb2312: 134
  ChineseBig5: 136
  Greek: 161
  Turkish: 162
  Vietnamese: 163
  Hebrew: 177
  Arabic: 178
  Baltic: 186
  Russian: 204
  Thai: 222
  EastEurope: 238
  Oem: 255
}

---GDI's text-measurement calls and the constants LOGFONTW takes.
---@class FfiGdi
---@field isAvailable boolean Whether gdi32 loaded; gate any use of `gdi32` on it.
---@field gdi32 table<string, ffi.cdata*> The bound GDI calls keyed by their Win32 names, or nil where the library couldn't be loaded.
---@field FACE_NAME_CAPACITY integer UTF-16 units LOGFONTW's face name holds, terminator included.
---@field LogFontW ffi.ctype* Constructor for a zeroed LOGFONTW, describing a font to realize.
---@field Size ffi.ctype* Constructor for a zeroed SIZE, which the extent calls fill in.
---@field TextMetricW ffi.ctype* Constructor for a zeroed TEXTMETRICW, which GetTextMetricsW fills in.
---@field MapMode Enum The map modes, as a GdiMapMode enum.
---@field FontWeight Enum The font weights, as a GdiFontWeight enum.
---@field OutputPrecision Enum The output precisions, as a GdiOutputPrecision enum.
---@field ClipPrecision table<string, GdiClipPrecision> Clip precisions and their flags, keyed by name.
---@field FontQuality Enum The rendering qualities, as a GdiFontQuality enum.
---@field FontPitch Enum The pitches, as a GdiFontPitch enum.
---@field FontFamily Enum The families, as a GdiFontFamily enum.
---@field CharSet Enum The character sets, as a GdiCharSet enum.
return {
  ---@type boolean
  isAvailable: isAvailable

  ---@type table<string, ffi.cdata*>
  gdi32: gdi32

  ---@type integer
  FACE_NAME_CAPACITY: ffi.sizeof(LogFontW!.lfFaceName) / WCHAR_SIZE

  ---@type ffi.ctype*
  LogFontW: LogFontW

  ---@type ffi.ctype*
  Size: Size

  ---@type ffi.ctype*
  TextMetricW: TextMetricW

  MapMode: MapMode
  FontWeight: FontWeight
  OutputPrecision: OutputPrecision
  FontQuality: FontQuality
  FontPitch: FontPitch
  FontFamily: FontFamily
  CharSet: CharSet

  ClipPrecision: {
    -- low nibble: three mutually exclusive alternatives
    Default: 0
    Character: 1
    Stroke: 2

    -- high nibble: flags to combine with one of the three above
    LeftHandedAngles: 0x10
    TrueTypeAlways: 0x20
    DisableFontAssociation: 0x40
    Embedded: 0x80

    -- spans the low nibble, but Windows documents it as unused and no GDI call reads it
    Mask: 0xF
  }
}
