-- Bindings for the Pango calls that lay out and measure text, plus the pangocairo entry point that
-- provides a font map without a display. Declarations are transcribed from Pango 1.57.0's
-- pango-layout.h, pango-font.h, pango-fontmap.h and pangocairo.h.
--
-- The opaque handles that cross between the three libraries — the font map and the context — are
-- declared as void pointers, since each bind prefixes its struct names and a value typed by one bind
-- cannot be passed where another bind's type is expected.

ffi = require "ffi"
Enum = require "l0.DependencyControl.Enum"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"

pangoBinding = ffiBinding.bind {
  -- a runtime install carries only the versioned soname, so the bare name is the last thing to try
  library: {"libpango-1.0.so.0", "libpango-1.0.0.dylib", "pango-1.0"}
  structs: {"PangoFontDescription", "PangoLayout", "PangoLayoutIter"}
  functions: {"pango_font_description_new", "pango_font_description_free",
    "pango_font_description_set_family", "pango_font_description_set_size",
    "pango_font_description_set_weight", "pango_font_description_set_style",
    "pango_font_map_create_context", "pango_layout_new", "pango_layout_set_font_description",
    "pango_layout_set_text", "pango_layout_get_pixel_size", "pango_layout_get_iter",
    "pango_layout_iter_get_baseline", "pango_layout_iter_free"}
  declarations: [[
    typedef struct PangoFontDescription PangoFontDescription;
    typedef struct PangoLayout PangoLayout;
    typedef struct PangoLayoutIter PangoLayoutIter;

    PangoFontDescription* pango_font_description_new(void);
    void pango_font_description_free(PangoFontDescription* description);
    void pango_font_description_set_family(PangoFontDescription* description, const char* family);
    void pango_font_description_set_size(PangoFontDescription* description, int size);
    void pango_font_description_set_weight(PangoFontDescription* description, int weight);
    void pango_font_description_set_style(PangoFontDescription* description, int style);
    void* pango_font_map_create_context(void* fontMap);
    PangoLayout* pango_layout_new(void* context);
    void pango_layout_set_font_description(PangoLayout* layout, const PangoFontDescription* description);
    void pango_layout_set_text(PangoLayout* layout, const char* text, int length);
    void pango_layout_get_pixel_size(PangoLayout* layout, int* width, int* height);
    PangoLayoutIter* pango_layout_get_iter(PangoLayout* layout);
    int pango_layout_iter_get_baseline(PangoLayoutIter* iter);
    void pango_layout_iter_free(PangoLayoutIter* iter);
  ]]
}

pangocairoBinding = ffiBinding.bind {
  library: {"libpangocairo-1.0.so.0", "libpangocairo-1.0.0.dylib", "pangocairo-1.0"}
  functions: {"pango_cairo_font_map_get_default", "pango_cairo_context_set_resolution"}
  declarations: [[
    void* pango_cairo_font_map_get_default(void);
    void pango_cairo_context_set_resolution(void* context, double dpi);
  ]]
}

gobjectBinding = ffiBinding.bind {
  library: {"libgobject-2.0.so.0", "libgobject-2.0.0.dylib", "gobject-2.0"}
  functions: {"g_object_unref"}
  declarations: [[
    void g_object_unref(void* object);
  ]]
}

isAvailable = pangoBinding.isAvailable and pangocairoBinding.isAvailable and
  gobjectBinding.isAvailable

-- Pango expresses sizes and positions in these fixed-point units per point or pixel.
PANGO_SCALE = 1024

PixelSizeOut = ffi.typeof "int[2]"

---How heavy a face's strokes are, on the OpenType scale Pango shares.
---@alias PangoFontWeight
---| 100 # Thin
---| 200 # UltraLight
---| 300 # Light
---| 350 # SemiLight
---| 380 # Book
---| 400 # Normal: the upright weight of a normal face
---| 500 # Medium
---| 600 # SemiBold
---| 700 # Bold: what an ASS style's bold flag asks for
---| 800 # UltraBold
---| 900 # Heavy
---| 1000 # UltraHeavy

---How far a face's glyphs lean.
---@alias PangoFontStyle
---| 0 # Normal: upright
---| 1 # Oblique: an upright face sheared, without redrawn letterforms
---| 2 # Italic: a drawn italic cut, whose letterforms differ from the upright

FontWeight = Enum "PangoFontWeight", {
  Thin: 100
  UltraLight: 200
  Light: 300
  SemiLight: 350
  Book: 380
  Normal: 400
  Medium: 500
  SemiBold: 600
  Bold: 700
  UltraBold: 800
  Heavy: 900
  UltraHeavy: 1000
}

FontStyle = Enum "PangoFontStyle", {
  Normal: 0
  Oblique: 1
  Italic: 2
}

---Pango's text-layout and measurement calls, with the pangocairo font map that works headlessly.
---@class FfiPango
---@field isAvailable boolean Whether Pango, pangocairo and GObject all loaded; gate any use on it.
---@field pango ffi.namespace* The loaded Pango library, or nil where it couldn't be loaded.
---@field pangocairo ffi.namespace* The loaded pangocairo library, or nil where it couldn't be loaded.
---@field gobject ffi.namespace* The loaded GObject library, or nil where it couldn't be loaded.
---@field PixelSizeOut ffi.ctype* Constructor for the two-int array pango_layout_get_pixel_size writes into.
---@field PANGO_SCALE integer Fixed-point units per point or pixel in Pango's size values.
---@field FontWeight Enum The weights, as a PangoFontWeight enum.
---@field FontStyle Enum The slants, as a PangoFontStyle enum.
return {
  ---@type boolean
  isAvailable: isAvailable

  ---@type ffi.namespace*
  pango: isAvailable and pangoBinding.functions or nil

  ---@type ffi.namespace*
  pangocairo: isAvailable and pangocairoBinding.functions or nil

  ---@type ffi.namespace*
  gobject: isAvailable and gobjectBinding.functions or nil

  ---@type ffi.ctype*
  PixelSizeOut: PixelSizeOut

  ---@type integer
  PANGO_SCALE: PANGO_SCALE

  FontWeight: FontWeight
  FontStyle: FontStyle
}
