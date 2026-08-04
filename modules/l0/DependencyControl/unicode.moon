{:band, :bor, :lshift, :rshift} = require "bit"
Enum = require "l0.DependencyControl.Enum"
utils = require "l0.DependencyControl.utils"

msgs = {
  malformed: "The text is not valid UTF-8: the sequence at byte %d is malformed."
  notEncodable: "Entry %d is not an encodable code point: %s."
}

-- UTF-8 spreads a code point over one to four bytes: a lead byte whose high bits mark the width,
-- then a continuation byte per further six bits of payload.
CONTINUATION_PAYLOAD_BITS = 6 -- payload bits a continuation byte carries
CONTINUATION_PAYLOAD_MASK = 2^CONTINUATION_PAYLOAD_BITS - 1 -- those bits, below the marker
CONTINUATION_MARKER = 0x80 -- the 10xxxxxx prefix every continuation byte carries
LAST_CONTINUATION_BYTE = bor CONTINUATION_MARKER, CONTINUATION_PAYLOAD_MASK

-- A lead byte opens with one 1 bit per byte of its sequence and then a 0, so the wider the sequence,
-- the fewer bits its lead byte has left for the code point's payload.
LEAD_MARKER_TWO_BYTE, LEAD_MARKER_THREE_BYTE, LEAD_MARKER_FOUR_BYTE = 0xC0, 0xE0, 0xF0
LEAD_MARKER_BY_WIDTH = {0, LEAD_MARKER_TWO_BYTE, LEAD_MARKER_THREE_BYTE, LEAD_MARKER_FOUR_BYTE}
LEAD_PAYLOAD_BITS_PER_WIDTH = {7, 5, 4, 3}
LEAD_PAYLOAD_MASK_PER_WIDTH = [2^bits - 1 for bits in *LEAD_PAYLOAD_BITS_PER_WIDTH]

-- The smallest code point a sequence may encode at each byte width before being considered overlong.
SHORTEST_TWO_BYTE_CODE_POINT = 0x80
SHORTEST_THREE_BYTE_CODE_POINT = 0x800
-- Beyond the end of the Basic Multilingual Plane, UTF-8 takes a fourth byte, and UTF-16 a surrogate pair.
FIRST_ASTRAL_CODE_POINT = 0x10000
-- The top of the Unicode codespace and the highest code point representable in UTF-16.
LAST_CODE_POINT = 0x10FFFF

-- Any code point using more bytes than necessary is overlong and rejected by a strict decode.
SHORTEST_CODE_POINT_BY_WIDTH = {0, SHORTEST_TWO_BYTE_CODE_POINT, SHORTEST_THREE_BYTE_CODE_POINT,
  FIRST_ASTRAL_CODE_POINT}

---Reports the lead byte a code point encodes to in a sequence of the given width.
---@param codePoint integer The code point to encode.
---@param width integer The sequence width, 1 through 4.
---@return integer leadByte The sequence's first byte, its marker and the code point's top bits combined.
getLeadByteFor = (codePoint, width) ->
  bor LEAD_MARKER_BY_WIDTH[width], rshift codePoint, (width - 1) * CONTINUATION_PAYLOAD_BITS

-- A two-byte sequence encoding anything below SHORTEST_TWO_BYTE_CODE_POINT is overlong, and no
-- sequence may encode past LAST_CODE_POINT, so the lead bytes those two code points encode constitute
-- the bounds of the legal lead range. C0 and C1 fall below the floor and could only ever open an overlong
-- sequence, while F5 and above address nothing. Two bytes is the one width whose floor reaches its
-- lead byte, since the smallest three- and four-byte code points leave that byte's payload zero.
SMALLEST_TWO_BYTE_LEAD = getLeadByteFor SHORTEST_TWO_BYTE_CODE_POINT, 2
LARGEST_LEAD = getLeadByteFor LAST_CODE_POINT, 4

-- The surrogates are reserved for UTF-16's astral encoding, so UTF-8 may carry none of them. A pair
-- splits the code point's twenty bits down the middle: the lead surrogate carries the top (high) ten,
-- the trail surrogate the bottom (low) ten. The standard allocates the lead block in a lower range
-- than the trail block.
FIRST_LEAD_SURROGATE, FIRST_TRAIL_SURROGATE, LAST_TRAIL_SURROGATE = 0xD800, 0xDC00, 0xDFFF
SURROGATE_PAYLOAD_BITS = 10 -- code point bits each surrogate of a pair carries
SURROGATE_PAYLOAD_MASK = 2^SURROGATE_PAYLOAD_BITS - 1 -- those bits, for the trail surrogate

-- stands in for text that could not be decoded, so a conversion can complete without failing
REPLACEMENT_CODE_POINT = 0xFFFD

---How text that cannot be represented is treated: malformed bytes when decoding, and values that are
---not code points when encoding.
---@alias UnicodeDecodeMode
---| 1 # Strict: rejects overlong sequences, encoded surrogates, out-of-range code points, stray continuation bytes and truncated tails
---| 2 # Replace: substitutes U+FFFD for each ill-formed sequence and carries on, resynchronizing on the maximal subpart the standard prescribes, so any byte string decodes and any list of values encodes
---| 3 # AegisubCompatibility: takes the width from the lead byte alone and decodes whatever follows, never failing, as Aegisub's own unicode module does; malformed bytes yield negative and above-range code points that only a Replace encode takes back. Encoding has no Aegisub behavior to reproduce and follows Replace.
DecodeMode = Enum "UnicodeDecodeMode", {
  Strict: 1
  Replace: 2
  AegisubCompatibility: 3
}

---Reports the byte width of the sequence a lead byte opens, taking the width from the lead byte alone,
---and whether that byte may open a sequence at all.
---@param leadByte integer The byte opening the sequence.
---@return integer width Byte width, 1 through 4, as the byte claims it whether or not the byte is a legal lead.
---@return boolean isWellFormedLead False for a continuation byte, an overlong-only lead, and a lead above the last legal one.
getLeadByteWidth = (leadByte) ->
  return 1, true if leadByte < SHORTEST_TWO_BYTE_CODE_POINT
  return 2, leadByte >= SMALLEST_TWO_BYTE_LEAD if leadByte < LEAD_MARKER_THREE_BYTE
  return 3, true if leadByte < LEAD_MARKER_FOUR_BYTE
  return 4, leadByte <= LARGEST_LEAD

---Returns the value of a single continuation byte in the UTF-8 sequence a code point encodes to.
---@param codePoint integer The code point being encoded.
---@param position integer Which byte of the sequence to return, 2 through 4.
---@param width integer The sequence's total byte width, 2 through 4.
---@return integer byte The continuation marker plus the payload bits carried at that position.
getContinuationByte = (codePoint, position, width) ->
  trailingPayloadBits = (width - position) * CONTINUATION_PAYLOAD_BITS
  bor CONTINUATION_MARKER, band rshift(codePoint, trailingPayloadBits), CONTINUATION_PAYLOAD_MASK

-- Derives the second byte's legal range for every lead byte that can open a multi-byte sequence,
-- identical to the [Table 3-7: Well-Formed UTF-8 Byte Sequences](https://www.unicode.org/versions/Unicode16.0.0/core-spec/chapter-3/#G27506)
-- table of the Unicode standard.
-- We only need one for the second byte, as every bit that decides whether a sequence is well-formed
-- lives in that range (the overlong threshold, the surrogate block, and the U+10FFFF codespace ceiling).
-- Nothing is left to decide by the third byte, so it and the fourth take the whole
-- continuation range (0x80..0xBF). A decode checks each byte against these ranges and stops at the first one
-- outside them, which ends the maximal subpart Unicode has a substituting decode replace with a
-- single character.
SECOND_BYTE_MIN_BY_LEAD, SECOND_BYTE_MAX_BY_LEAD = {}, {}
for leadByte = SMALLEST_TWO_BYTE_LEAD, LARGEST_LEAD
  width = getLeadByteWidth leadByte
  totalContinuationPayloadBits = (width - 1) * CONTINUATION_PAYLOAD_BITS
  lowestCodepoint = lshift band(leadByte, LEAD_PAYLOAD_MASK_PER_WIDTH[width]), totalContinuationPayloadBits
  highestCodepoint = bor lowestCodepoint, lshift(1, totalContinuationPayloadBits) - 1

  lowestCodepoint = math.max lowestCodepoint, SHORTEST_CODE_POINT_BY_WIDTH[width]
  highestCodepoint = math.min highestCodepoint, LAST_CODE_POINT
  if lowestCodepoint < FIRST_LEAD_SURROGATE and highestCodepoint >= FIRST_LEAD_SURROGATE
    highestCodepoint = FIRST_LEAD_SURROGATE - 1

  SECOND_BYTE_MIN_BY_LEAD[leadByte] = getContinuationByte lowestCodepoint, 2, width
  SECOND_BYTE_MAX_BY_LEAD[leadByte] = getContinuationByte highestCodepoint, 2, width

---Decodes the sequence starting at a byte offset.
---
---For an ill-formed sequence the byte count returned is the Unicode standard's maximal subpart, i.e.
---the longest prefix that could still have grown into a well-formed sequence. Advancing by the width
--- indicated by the lead byte instead of the maximal subpart would swallow whatever follows instead
---(e.g. `E0 80 41` would lose the `A`).
---@param text string The text to read.
---@param byteOffset integer Offset of the sequence's lead byte.
---@return integer? codePoint Nil where the sequence is ill-formed.
---@return integer consumed The sequence's width where well-formed, its maximal subpart's length where not, and zero past the end of the text.
decodeSequenceWellFormed = (text, byteOffset) ->
  leadByte = text\byte byteOffset
  return nil, 0 unless leadByte

  width, isWellFormedLead = getLeadByteWidth leadByte
  return nil, 1 unless isWellFormedLead

  codePoint = band leadByte, LEAD_PAYLOAD_MASK_PER_WIDTH[width]
  minimum, maximum = SECOND_BYTE_MIN_BY_LEAD[leadByte], SECOND_BYTE_MAX_BY_LEAD[leadByte]
  for offset = 1, width - 1
    continuation = text\byte byteOffset + offset
    return nil, offset unless continuation and continuation >= minimum and continuation <= maximum
    payload = band continuation, CONTINUATION_PAYLOAD_MASK
    codePoint = bor lshift(codePoint, CONTINUATION_PAYLOAD_BITS), payload
    minimum, maximum = CONTINUATION_MARKER, LAST_CONTINUATION_BYTE

  -- Overlong sequences, encoded surrogates and code points past U+10FFFF need no check of their own
  -- as the second byte's range already excluded every one of them before the loop assembled anything.
  return codePoint, width

---Decodes the sequence starting at a byte offset the way Aegisub's own unicode module does, taking the
---width from the lead byte alone and decoding whatever follows it. It validates nothing, so it answers
---for input no UTF-8 decoder should accept, and in which case the answer is often not a code point at all.
---
---What it gets wrong, with the values it returns:
--- * An overlong sequence decodes to the character it pads, so `C0 AF` yields 47, a `/` that has slipped
---   past any filter reading bytes, and `E0 80 80` yields 0.
--- * A stray continuation byte opens a sequence of its own. It reads as a two-byte lead, and no marker
---   sits at that width to subtract, so `80` yields -4096.
--- * Continuation bytes are never checked, so an ASCII byte inside a sequence becomes payload and never
---   resynchronizes the walk. `E4 28 B8` yields 10808 and swallows the `(`.
--- * A tail shorter than the lead byte claims is decoded as though the missing bytes carried no payload,
---   so the two bytes `E4 B8` invent U+4E00. Aegisub raises here instead of answering.
--- * An encoded surrogate and a code point above U+10FFFF both pass straight through, so `ED A0 BD`
---   yields 55357 and `F5 8F BF BF` yields 1376255.
---
---Negative and above-range answers are not code points, so neither encoder takes one back and a
---decode-then-encode round trip through this mode fails by design.
---@param text string The text to read.
---@param byteOffset integer Offset of the sequence's lead byte.
---@return integer? codePoint Nil only where the offset lies past the end of the text.
---@return integer|string widthOrError The width the lead byte claimed, or why it was rejected.
decodeSequenceAegisub = (text, byteOffset) ->
  leadByte = text\byte byteOffset
  return nil, msgs.malformed\format byteOffset unless leadByte

  width = getLeadByteWidth leadByte
  -- Every byte has its marker subtracted whether or not it actually carries one, which is where the
  -- negative and above-range answers come from. Masking would confine each byte to its payload bits
  -- and lose the out-of-range values this mode exists to reproduce.
  codePoint = leadByte - LEAD_MARKER_BY_WIDTH[width]
  for offset = 1, width - 1
    -- Treat a byte past the end of the text as if it were the bare marker w/o payload, so a truncated tail still decodes.
    continuation = text\byte(byteOffset + offset) or CONTINUATION_MARKER
    codePoint = lshift(codePoint, CONTINUATION_PAYLOAD_BITS) + continuation - CONTINUATION_MARKER

  return codePoint, width

---Decodes the sequence starting at a byte offset by the rules the mode asks for.
---@param text string The text to read.
---@param byteOffset integer Offset of the sequence's lead byte.
---@param mode UnicodeDecodeMode The mode to decode by, already validated by the caller.
---@return integer? codePoint U+FFFD under Replace where the sequence was ill-formed, nil where it was rejected.
---@return integer|string widthOrError Bytes the returned code point stands for, or why the sequence was rejected.
decodeSequence = (text, byteOffset, mode) ->
  return decodeSequenceAegisub text, byteOffset if mode == DecodeMode.AegisubCompatibility

  codePoint, consumed = decodeSequenceWellFormed text, byteOffset
  return codePoint, consumed if codePoint
  -- a zero count means the offset lies past the end, where no mode has a character to answer with
  return REPLACEMENT_CODE_POINT, consumed if mode == DecodeMode.Replace and consumed > 0
  return nil, msgs.malformed\format byteOffset

---Reports whether a value is a code point both UTF-8 and UTF-16 can carry.
---@param codePoint any The value to check.
---@return boolean encodable True for an integer in [0, LAST_CODE_POINT] that is not a surrogate.
isEncodable = (codePoint) ->
  return false unless "number" == type(codePoint) and codePoint % 1 == 0
  return false if codePoint < 0 or codePoint > LAST_CODE_POINT
  return codePoint < FIRST_LEAD_SURROGATE or codePoint > LAST_TRAIL_SURROGATE

---UTF-8 inspection, decoding and encoding, and the UTF-16 conversion the platform text APIs take.
---Every function works strictly unless given another `DecodeMode`. Ask for `Strict` where bad bytes
---have to be heard about before text reaches a font or a system call, `Replace` where untrusted text
---has to be sanitized and the work has to finish whatever it holds, and `AegisubCompatibility` where
---the point is to answer as Aegisub's own unicode module does.
---@class Unicode
---@field DecodeMode Enum The modes, as a UnicodeDecodeMode enum.
---@field REPLACEMENT_CODE_POINT integer U+FFFD, standing in for text that could not be represented.
local Unicode
Unicode = {
  DecodeMode: DecodeMode
  REPLACEMENT_CODE_POINT: REPLACEMENT_CODE_POINT

  ---Returns the number of bytes the character starting at a byte offset occupies.
  ---@param text string The text to read.
  ---@param byteOffset? integer Offset of the character's first byte (default 1).
  ---@param mode? UnicodeDecodeMode How to treat malformed input (default Strict).
  ---@return integer? width Bytes the character occupies, which in Replace mode is what one U+FFFD stands for; 1 for an offset past the end under AegisubCompatibility, nil where the read was rejected.
  ---@return string? err Why the read was rejected.
  getCharWidth: (text, byteOffset = 1, mode = DecodeMode.Strict) ->
    utils.assertArgType text, 1, "string"
    assert DecodeMode\validate mode, "mode"
    -- Aegisub answers 1 for an offset past the end rather than failing, and karaskel relies on it
    return 1 if mode == DecodeMode.AegisubCompatibility and not text\byte byteOffset

    _, widthOrError = decodeSequence text, byteOffset, mode
    return nil, widthOrError if "string" == type widthOrError
    return widthOrError

  ---Returns the code point of the character starting at a byte offset.
  ---@param text string The text to read.
  ---@param byteOffset? integer Offset of the character's first byte (default 1).
  ---@param mode? UnicodeDecodeMode How to treat malformed input (default Strict).
  ---@return integer? codePoint U+FFFD in Replace mode where the sequence was ill-formed, nil where the read was rejected.
  ---@return string? err Why it was rejected.
  getCodePoint: (text, byteOffset = 1, mode = DecodeMode.Strict) ->
    utils.assertArgType text, 1, "string"
    assert DecodeMode\validate mode, "mode"
    codePoint, widthOrError = decodeSequence text, byteOffset, mode
    return nil, widthOrError unless codePoint
    return codePoint

  ---Decodes UTF-8 into the code points it carries.
  ---@param text string The text to decode.
  ---@param mode? UnicodeDecodeMode How to treat malformed input (default Strict).
  ---@return integer[]? codePoints One entry per character, with a U+FFFD per ill-formed sequence in Replace mode; empty for an empty string.
  ---@return string? err Which byte the first rejected sequence starts at.
  decodeUtf8: (text, mode = DecodeMode.Strict) ->
    utils.assertArgType text, 1, "string"
    assert DecodeMode\validate mode, "mode"

    codePoints, position, length = {}, 1, #text
    while position <= length
      codePoint, widthOrError = decodeSequence text, position, mode
      return nil, widthOrError unless codePoint
      codePoints[#codePoints + 1] = codePoint
      position += widthOrError

    return codePoints

  ---Iterates the characters of a string, yielding each as an individual 1-to-4 byte string.
  ---A strict iterator validates the whole string up front, so the iteration itself never fails.
  ---@param text string The text to walk.
  ---@param mode? UnicodeDecodeMode How to treat malformed input (default Strict).
  ---@return fun(): string?, integer? iterator Yields each character with its 1-based index, nil where a strict walk rejected the text.
  ---@return string? err Which byte the first rejected sequence starts at.
  iterateChars: (text, mode = DecodeMode.Strict) ->
    utils.assertArgType text, 1, "string"
    assert DecodeMode\validate mode, "mode"
    if mode == DecodeMode.Strict
      _, err = Unicode.decodeUtf8 text, DecodeMode.Strict
      return nil, err if err

    -- the decoder reports how many bytes to advance, which in Replace mode is the maximal subpart,
    -- so a substituted character covers the bytes it stands for
    characterIndex, position = 0, 1
    return ->
      return if position > #text

      start = position
      characterIndex += 1
      _, width = decodeSequence text, position, mode
      position += width
      return text\sub(start, position - 1), characterIndex

  ---Counts the characters in a string.
  ---Has to read the string end to end, since UTF-8 stores no count to read.
  ---@param text string The text to measure.
  ---@param mode? UnicodeDecodeMode How to treat malformed input (default Strict).
  ---@return integer? length Character count, not byte count.
  ---@return string? err Which byte the first rejected sequence starts at.
  getLength: (text, mode) ->
    iterator, err = Unicode.iterateChars text, mode
    return nil, err unless iterator

    count = 0
    count += 1 for _ in iterator
    return count

  ---Encodes code points as UTF-8.
  ---An entry that is not a code point is rejected, or replaced by U+FFFD in Replace mode.
  ---@param codePoints integer[] The code points to encode, each an integer in [0, 0x10FFFF] and not a surrogate.
  ---@param mode? UnicodeDecodeMode How to treat an entry that is not a code point (default Strict).
  ---@return string? text The encoded text, nil where an entry was rejected.
  ---@return string? err Which entry was rejected, and the value it held.
  encodeUtf8: (codePoints, mode = DecodeMode.Strict) ->
    utils.assertArgType codePoints, 1, "table"
    assert DecodeMode\validate mode, "mode"
    strict = mode == DecodeMode.Strict

    bytes, sequence = {}, {}
    for index, codePoint in ipairs codePoints
      unless isEncodable codePoint
        return nil, msgs.notEncodable\format index, tostring codePoint if strict
        codePoint = REPLACEMENT_CODE_POINT

      width = 1
      while width < #SHORTEST_CODE_POINT_BY_WIDTH and
        codePoint >= SHORTEST_CODE_POINT_BY_WIDTH[width + 1]
        width += 1

      -- the continuation bytes carry the low six bits each, so they fill in from the back
      remaining = codePoint
      for position = width, 2, -1
        sequence[position] = bor CONTINUATION_MARKER, band remaining, CONTINUATION_PAYLOAD_MASK
        remaining = rshift remaining, CONTINUATION_PAYLOAD_BITS
      sequence[1] = bor LEAD_MARKER_BY_WIDTH[width], remaining

      bytes[#bytes + 1] = string.char unpack sequence, 1, width

    return table.concat bytes

  ---Decodes UTF-16 code units into the code points they carry.
  ---A non-strict decode substitutes U+FFFD for any unpaired surrogate.
  ---@param units integer[] The code units to decode.
  ---@param mode? UnicodeDecodeMode How to treat an unpaired surrogate (default Strict).
  ---@return integer[]? codePoints Nil where a strict decode met an unpaired surrogate.
  ---@return string? err Which unit the unpaired surrogate sits at.
  decodeUtf16: (units, mode = DecodeMode.Strict) ->
    utils.assertArgType units, 1, "table"
    assert DecodeMode\validate mode, "mode"
    strict = mode == DecodeMode.Strict

    codePoints, index, count = {}, 1, #units
    while index <= count
      unit = units[index]
      following = units[index + 1]
      isLeadSurrogate = unit >= FIRST_LEAD_SURROGATE and unit < FIRST_TRAIL_SURROGATE
      isPaired = isLeadSurrogate and following and following >= FIRST_TRAIL_SURROGATE and
        following <= LAST_TRAIL_SURROGATE

      if isPaired
        codePoints[#codePoints + 1] = FIRST_ASTRAL_CODE_POINT +
          lshift(unit - FIRST_LEAD_SURROGATE, SURROGATE_PAYLOAD_BITS) +
          following - FIRST_TRAIL_SURROGATE
        index += 2
      elseif unit >= FIRST_LEAD_SURROGATE and unit <= LAST_TRAIL_SURROGATE
        return nil, msgs.malformed\format index if strict
        -- an unpaired surrogate is not a character, so it stands in as the replacement one
        codePoints[#codePoints + 1] = REPLACEMENT_CODE_POINT
        index += 1
      else
        codePoints[#codePoints + 1] = unit
        index += 1

    return codePoints

  ---Converts code points to the UTF-16 code units the platform text APIs take. An entry that is not a
  ---code point is rejected, or replaced by U+FFFD in Replace mode.
  ---@param codePoints integer[] The code points to convert, each an integer in [0, 0x10FFFF] and not a surrogate.
  ---@param mode? UnicodeDecodeMode How to treat an entry that is not a code point (default Strict).
  ---@return integer[]? units One unit per BMP code point, two per astral one; nil where an entry was rejected.
  ---@return integer[]|string unitOffsetsOrError Zero-based index into `units` of each code point's first unit, or why an entry was rejected.
  encodeUtf16: (codePoints, mode = DecodeMode.Strict) ->
    utils.assertArgType codePoints, 1, "table"
    assert DecodeMode\validate mode, "mode"
    strict = mode == DecodeMode.Strict

    units, unitOffsets = {}, {}
    for index, codePoint in ipairs codePoints
      unless isEncodable codePoint
        return nil, msgs.notEncodable\format index, tostring codePoint if strict
        codePoint = REPLACEMENT_CODE_POINT

      unitOffsets[#unitOffsets + 1] = #units
      if codePoint < FIRST_ASTRAL_CODE_POINT
        units[#units + 1] = codePoint
      else
        adjusted = codePoint - FIRST_ASTRAL_CODE_POINT
        units[#units + 1] = bor FIRST_LEAD_SURROGATE, rshift adjusted, SURROGATE_PAYLOAD_BITS
        units[#units + 1] = bor FIRST_TRAIL_SURROGATE, band adjusted, SURROGATE_PAYLOAD_MASK

    return units, unitOffsets
}

return Unicode
