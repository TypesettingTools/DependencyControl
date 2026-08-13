Enum = require "l0.DependencyControl.Enum"

---What a cmap subtable is keyed by, which decides how a code point reaches a glyph in it.
---@alias FontEncoding
---| 1 # Unicode: code points, which every subtable a modern face states is keyed by
---| 2 # MacRoman: a Mac OS Roman byte, which a `platform 1 / encoding 0` subtable is keyed by
---| 3 # Symbol: a byte offset into the private use area, which a `platform 3 / encoding 0` subtable is keyed by
Encoding = Enum "FontEncoding", {
  Unicode: 1
  MacRoman: 2
  Symbol: 3
}

-- Byte 0x7F and below is ASCII, which Mac OS Roman leaves alone, so only the high half is tabulated.
-- The table is verified byte for byte against FreeType by reading the same glyph out of a face that
-- carries both a Mac Roman and a Unicode subtable, once through each.
MAC_ROMAN_FIRST_BYTE = 0x80

---The code point each high byte stands for, transcribed from the Mac OS Roman table. Two revisions
---disagree on byte 0xDB alone, which was the currency sign until Mac OS 8.5 and the euro sign after.
---The later reading is the one here, as FreeType and the Unicode consortium's own mapping both take it.
codePointsByMacRomanByte = {
  [MAC_ROMAN_FIRST_BYTE]: 0x00C4, [0x81]: 0x00C5, [0x82]: 0x00C7, [0x83]: 0x00C9
  [0x84]: 0x00D1, [0x85]: 0x00D6, [0x86]: 0x00DC, [0x87]: 0x00E1, [0x88]: 0x00E0, [0x89]: 0x00E2,
  [0x8A]: 0x00E4, [0x8B]: 0x00E3, [0x8C]: 0x00E5, [0x8D]: 0x00E7, [0x8E]: 0x00E9, [0x8F]: 0x00E8,
  [0x90]: 0x00EA, [0x91]: 0x00EB, [0x92]: 0x00ED, [0x93]: 0x00EC, [0x94]: 0x00EE, [0x95]: 0x00EF,
  [0x96]: 0x00F1, [0x97]: 0x00F3, [0x98]: 0x00F2, [0x99]: 0x00F4, [0x9A]: 0x00F6, [0x9B]: 0x00F5,
  [0x9C]: 0x00FA, [0x9D]: 0x00F9, [0x9E]: 0x00FB, [0x9F]: 0x00FC, [0xA0]: 0x2020, [0xA1]: 0x00B0,
  [0xA2]: 0x00A2, [0xA3]: 0x00A3, [0xA4]: 0x00A7, [0xA5]: 0x2022, [0xA6]: 0x00B6, [0xA7]: 0x00DF,
  [0xA8]: 0x00AE, [0xA9]: 0x00A9, [0xAA]: 0x2122, [0xAB]: 0x00B4, [0xAC]: 0x00A8, [0xAD]: 0x2260,
  [0xAE]: 0x00C6, [0xAF]: 0x00D8, [0xB0]: 0x221E, [0xB1]: 0x00B1, [0xB2]: 0x2264, [0xB3]: 0x2265,
  [0xB4]: 0x00A5, [0xB5]: 0x00B5, [0xB6]: 0x2202, [0xB7]: 0x2211, [0xB8]: 0x220F, [0xB9]: 0x03C0,
  [0xBA]: 0x222B, [0xBB]: 0x00AA, [0xBC]: 0x00BA, [0xBD]: 0x2126, [0xBE]: 0x00E6, [0xBF]: 0x00F8,
  [0xC0]: 0x00BF, [0xC1]: 0x00A1, [0xC2]: 0x00AC, [0xC3]: 0x221A, [0xC4]: 0x0192, [0xC5]: 0x2248,
  [0xC6]: 0x2206, [0xC7]: 0x00AB, [0xC8]: 0x00BB, [0xC9]: 0x2026, [0xCA]: 0x00A0, [0xCB]: 0x00C0
  [0xCC]: 0x00C3, [0xCD]: 0x00D5, [0xCE]: 0x0152, [0xCF]: 0x0153, [0xD0]: 0x2013, [0xD1]: 0x2014,
  [0xD2]: 0x201C, [0xD3]: 0x201D, [0xD4]: 0x2018, [0xD5]: 0x2019, [0xD6]: 0x00F7, [0xD7]: 0x25CA,
  [0xD8]: 0x00FF, [0xD9]: 0x0178, [0xDA]: 0x2044, [0xDB]: 0x20AC, [0xDC]: 0x2039, [0xDD]: 0x203A,
  [0xDE]: 0xFB01, [0xDF]: 0xFB02, [0xE0]: 0x2021, [0xE1]: 0x00B7, [0xE2]: 0x201A, [0xE3]: 0x201E,
  [0xE4]: 0x2030, [0xE5]: 0x00C2, [0xE6]: 0x00CA, [0xE7]: 0x00C1, [0xE8]: 0x00CB, [0xE9]: 0x00C8,
  [0xEA]: 0x00CD, [0xEB]: 0x00CE, [0xEC]: 0x00CF, [0xED]: 0x00CC, [0xEE]: 0x00D3, [0xEF]: 0x00D4,
  [0xF0]: 0xF8FF, [0xF1]: 0x00D2, [0xF2]: 0x00DA, [0xF3]: 0x00DB, [0xF4]: 0x00D9, [0xF5]: 0x0131,
  [0xF6]: 0x02C6, [0xF7]: 0x02DC, [0xF8]: 0x00AF, [0xF9]: 0x02D8, [0xFA]: 0x02D9, [0xFB]: 0x02DA,
  [0xFC]: 0x00B8, [0xFD]: 0x02DD, [0xFE]: 0x02DB, [0xFF]: 0x02C7,
}

macRomanBytesByCodePoint = {codePoint, byte for byte, codePoint in pairs codePointsByMacRomanByte}

-- A symbol subtable states its characters a plane into the private use area, so a byte reaches its
-- glyph at 0xF000 above itself. The subtable defines what each of them draws, this being an offset
-- rather than a character set, so there is nothing to tabulate.
SYMBOL_BASE = 0xF000
SYMBOL_FIRST_BYTE = 0x20
SYMBOL_LAST_BYTE = 0xFF

encoders = {
  [Encoding.Unicode]: (codePoint) -> codePoint

  [Encoding.MacRoman]: (codePoint) ->
    return codePoint if codePoint < MAC_ROMAN_FIRST_BYTE
    return macRomanBytesByCodePoint[codePoint]

  -- text already written in the private use area is passed through as it stands
  [Encoding.Symbol]: (codePoint) ->
    return codePoint if codePoint >= SYMBOL_BASE + SYMBOL_FIRST_BYTE and
      codePoint <= SYMBOL_BASE + SYMBOL_LAST_BYTE
    return nil unless codePoint >= SYMBOL_FIRST_BYTE and codePoint <= SYMBOL_LAST_BYTE
    return SYMBOL_BASE + codePoint
}

decoders = {
  [Encoding.Unicode]: (index) -> index

  [Encoding.MacRoman]: (index) ->
    return index if index < MAC_ROMAN_FIRST_BYTE
    return codePointsByMacRomanByte[index]

  [Encoding.Symbol]: (index) ->
    return index - SYMBOL_BASE if index >= SYMBOL_BASE + SYMBOL_FIRST_BYTE and
      index <= SYMBOL_BASE + SYMBOL_LAST_BYTE
    return index
}

---What a cmap subtable is keyed by, and the encoding and decoding between a code point and that key.
---@class AegisubShimsFontEncoding
---@field Encoding Enum The subtable keys on offer, as a FontEncoding enum.
FontEncoding = {
  :Encoding

  ---Returns the encoder taking a code point to the index one encoding is keyed by.
  ---
  ---Resolved once per face rather than per character, a measurement looking every character of a run
  ---up through the same subtable.
  ---@param encoding FontEncoding The encoding to encode for.
  ---@return fun(codePoint: integer): integer? encode Nil for a code point the encoding states no index for, which reaches no glyph.
  encoderFor: (encoding) -> encoders[encoding]

  ---Returns the decoder taking an index back to the code point it stands for.
  ---@param encoding FontEncoding The encoding to decode from.
  ---@return fun(index: integer): integer? decode Nil for an index the encoding states no character at.
  decoderFor: (encoding) -> decoders[encoding]
}

return FontEncoding
