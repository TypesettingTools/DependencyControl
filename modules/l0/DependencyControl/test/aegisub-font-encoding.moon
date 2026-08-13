-- Pins the conversions the FreeType backend takes a code point through for a face whose cmap states no
-- Unicode subtable. Pure table lookups, so it needs no font library and runs everywhere; the Mac OS
-- Roman table is checked byte for byte against FreeType by reading the same glyph out of a face that
-- carries both a Mac Roman and a Unicode subtable, once through each.
-- Called from test.moon as: (controls\requireTest "aegisub-font-encoding")!
->
  fontEncoding = require "l0.AegisubShims.helpers.font-encoding"
  {:Encoding} = fontEncoding

  macRoman = {
    fromCodePoint: fontEncoding.encoderFor Encoding.MacRoman
    toCodePoint: fontEncoding.decoderFor Encoding.MacRoman
  }
  symbol = fontEncoding.encoderFor Encoding.Symbol

  MAC_ROMAN_FIRST_BYTE = 0x80
  LAST_BYTE = 0xFF
  SYMBOL_BASE = 0xF000

  {
    _description: "The indexes a cmap subtable is keyed by"

    fromCodePoint_leavesAsciiAlone: (ut) ->
      ut\assertEquals macRoman.fromCodePoint(0x00), 0x00
      ut\assertEquals macRoman.fromCodePoint(0x41), 0x41
      ut\assertEquals macRoman.fromCodePoint(0x7F), 0x7F

    -- the two the FreeType check settled directly: é sits at 0x8E, and byte 0xE9 is È rather than é
    fromCodePoint_readsTheHighHalf: (ut) ->
      ut\assertEquals macRoman.fromCodePoint(0x00E9), 0x8E
      ut\assertEquals macRoman.fromCodePoint(0x00C8), 0xE9

    -- a character outside the encoding has no byte to look a glyph up by, which the caller reads as
    -- .notdef rather than passing the code point through to whatever byte it would collide with
    fromCodePoint_nilOutsideTheEncoding: (ut) ->
      ut\assertNil macRoman.fromCodePoint 0x4E00
      ut\assertNil macRoman.fromCodePoint 0x0100
      ut\assertNil macRoman.fromCodePoint 0x1F600

    toCodePoint_leavesAsciiAlone: (ut) ->
      ut\assertEquals macRoman.toCodePoint(0x41), 0x41
      ut\assertEquals macRoman.toCodePoint(0x7F), 0x7F

    toCodePoint_readsTheHighHalf: (ut) ->
      ut\assertEquals macRoman.toCodePoint(0x8E), 0x00E9
      ut\assertEquals macRoman.toCodePoint(0xE9), 0x00C8

    -- every high byte stands for a character, and each of the 128 for a different one
    toCodePoint_coversEveryHighByte: (ut) ->
      seen = {}
      for byte = MAC_ROMAN_FIRST_BYTE, LAST_BYTE
        codePoint = macRoman.toCodePoint byte
        ut\assertNotNil codePoint
        ut\assertNil seen[codePoint]
        seen[codePoint] = byte
      ut\assertEquals macRoman.fromCodePoint(codePoint), byte for codePoint, byte in pairs seen

    -- a symbol subtable is keyed by the byte offset into the private use area, not by a character set
    symbol_offsetsIntoThePrivateUseArea: (ut) ->
      ut\assertEquals symbol(0x41), SYMBOL_BASE + 0x41
      ut\assertEquals symbol(0x20), SYMBOL_BASE + 0x20
      ut\assertEquals symbol(0xFF), SYMBOL_BASE + 0xFF

    -- text already written in that area names its glyph directly
    symbol_passesThroughWhatIsAlreadyThere: (ut) ->
      ut\assertEquals symbol(SYMBOL_BASE + 0x41), SYMBOL_BASE + 0x41

    symbol_nilOutsideTheByteRange: (ut) ->
      ut\assertNil symbol 0x1F
      ut\assertNil symbol 0x4E00
      ut\assertNil symbol SYMBOL_BASE + 0x100

    unicode_isTheIdentity: (ut) ->
      convert = fontEncoding.encoderFor Encoding.Unicode
      ut\assertEquals convert(0x41), 0x41
      ut\assertEquals convert(0x4E00), 0x4E00
  }
