-- Pins the central UTF-8/UTF-16 helper in all three modes. Strict, the default, rejects every
-- ill-formed sequence the standard names; Replace substitutes U+FFFD and resynchronizes where the
-- standard says to; AegisubCompatibility reproduces the lead-byte walk Aegisub's own unicode module
-- performs, out-of-range answers included. The encoders refuse anything a code point cannot be unless
-- asked to replace it, so what they emit always survives a strict decode.
-- Called from test.moon as: (controls\requireTest "unicode")!
->
  unicode = require "l0.DependencyControl.unicode"
  {:AegisubCompatibility, :Replace, :Strict} = unicode.DecodeMode
  REPLACEMENT = unicode.REPLACEMENT_CODE_POINT

  -- ill-formed sequences, each named by what makes it ill-formed
  OVERLONG_SLASH = "\192\175"       -- "/" padded into two bytes
  OVERLONG_NUL = "\224\128\128"     -- NUL padded into three
  ENCODED_SURROGATE = "\237\160\189" -- a lead surrogate, which UTF-8 may not carry
  STRAY_CONTINUATION = "\128"
  TRUNCATED = "\228\184"            -- a three-byte lead with one continuation byte
  BAD_CONTINUATION = "\228\40\184"
  BEYOND_LAST_CODE_POINT = "\245\143\191\191"
  -- A three-byte lead, a second byte outside the range E0 admits, then an ASCII letter. Resynchronizing
  -- on the lead byte's claimed width would swallow the letter; the maximal subpart stops before it.
  OVERLONG_LEAD_THEN_ASCII = "\224\128\65"
  -- "a", then three ill-formed subparts of three, two and one bytes, then "b". Each lead byte is cut
  -- short by the next one, so the run exercises every subpart length a four-byte sequence can stop at.
  SUBPARTS_OF_DECREASING_LENGTH = "\97\241\128\128\225\128\194\98"
  -- a four-byte emoji with its last byte lost, which stays a single subpart because everything
  -- present could still have grown into the whole sequence
  TRUNCATED_EMOJI = "\240\159\153"

  EMOJI = "\240\159\152\128"        -- U+1F600, four bytes
  UMLAUT = "\195\188"               -- U+00FC, two bytes
  IDEOGRAPH_ONE = "\228\184\128"    -- U+4E00, three bytes

  FIRST_LEAD_SURROGATE, LAST_TRAIL_SURROGATE = 0xD800, 0xDFFF
  LAST_CODE_POINT = 0x10FFFF

  {
    _description: "The central Unicode helper, decoding strictly, replacing, and Aegisub-compatibly."

    getCharWidth_readsEachLeadByteWidth: (ut) ->
      ut\assertEquals unicode.getCharWidth("a"), 1
      ut\assertEquals unicode.getCharWidth(UMLAUT), 2
      ut\assertEquals unicode.getCharWidth(IDEOGRAPH_ONE), 3
      ut\assertEquals unicode.getCharWidth(EMOJI), 4

    getCharWidth_defaultsToTheFirstByte: (ut) ->
      ut\assertEquals unicode.getCharWidth("a#{EMOJI}", 2), 4

    -- Aegisub answers 1 for an offset past the end rather than failing, and karaskel relies on it
    getCharWidth_compatibilityAnswersOnePastTheEnd: (ut) ->
      ut\assertEquals unicode.getCharWidth("abc", 99, AegisubCompatibility), 1

    getCharWidth_strictRejectsAStrayContinuationByte: (ut) ->
      width, err = unicode.getCharWidth STRAY_CONTINUATION, 1, Strict
      ut\assertNil width
      ut\assertMatches err, "not valid UTF%-8"

    getCodePoint_decodesEachWidth: (ut) ->
      ut\assertEquals unicode.getCodePoint("a"), 0x61
      ut\assertEquals unicode.getCodePoint(UMLAUT), 0xFC
      ut\assertEquals unicode.getCodePoint(EMOJI), 0x1F600

    getCodePoint_readsFromAByteOffset: (ut) ->
      ut\assertEquals unicode.getCodePoint("ab#{EMOJI}", 3), 0x1F600

    -- the bytes that are there still yield a value, where reading past the end would fail
    getCodePoint_compatibilityDecodesATruncatedTail: (ut) ->
      ut\assertNumber unicode.getCodePoint TRUNCATED, 1, AegisubCompatibility

    decodeUtf8_decodesAMixedString: (ut) ->
      ut\assertItemsEqual unicode.decodeUtf8("a#{UMLAUT}#{EMOJI}"), {0x61, 0xFC, 0x1F600}

    decodeUtf8_decodesAnEmptyString: (ut) ->
      ut\assertItemsEqual unicode.decodeUtf8(""), {}

    decodeUtf8_strictAcceptsWellFormedText: (ut) ->
      ut\assertItemsEqual unicode.decodeUtf8("a#{UMLAUT}#{EMOJI}", Strict), {0x61, 0xFC, 0x1F600}

    -- an overlong sequence smuggles an ASCII character past a byte-level filter, so it is ill-formed
    decodeUtf8_strictRejectsOverlongSequences: (ut) ->
      ut\assertNil unicode.decodeUtf8 OVERLONG_SLASH, Strict
      ut\assertNil unicode.decodeUtf8 OVERLONG_NUL, Strict

    -- surrogates encode astral characters in UTF-16 only; UTF-8 carries the code point itself
    decodeUtf8_strictRejectsAnEncodedSurrogate: (ut) ->
      ut\assertNil unicode.decodeUtf8 ENCODED_SURROGATE, Strict

    decodeUtf8_strictRejectsMalformedSequences: (ut) ->
      for malformed in *{STRAY_CONTINUATION, TRUNCATED, BAD_CONTINUATION, BEYOND_LAST_CODE_POINT}
        codePoints, err = unicode.decodeUtf8 malformed, Strict
        ut\assertNil codePoints
        ut\assertMatches err, "not valid UTF%-8"

    decodeUtf8_namesTheByteTheBadSequenceStartsAt: (ut) ->
      _, err = unicode.decodeUtf8 "ab#{OVERLONG_SLASH}", Strict
      ut\assertMatches err, "byte 3"

    -- compatibility takes the width from the lead byte alone, so ill-formed input still walks
    decodeUtf8_compatibilityAcceptsWhatStrictRejects: (ut) ->
      ut\assertNotNil unicode.decodeUtf8 malformed, AegisubCompatibility for malformed in *{
        OVERLONG_SLASH, ENCODED_SURROGATE, TRUNCATED, BEYOND_LAST_CODE_POINT}

    -- The default guards a caller who never considered malformed input. Answering anyway is what has
    -- to be asked for by name, since those answers are values no encoder takes back.
    decodeMode_defaultsToStrict: (ut) ->
      ut\assertNil unicode.decodeUtf8 OVERLONG_SLASH
      ut\assertNil unicode.getCharWidth "abc", 99
      ut\assertNil unicode.getCodePoint TRUNCATED
      ut\assertNil unicode.getLength "a#{ENCODED_SURROGATE}"
      ut\assertNil unicode.iterateChars "a#{OVERLONG_SLASH}"

    -- One replacement character per maximal subpart, not per byte and not per run: three subparts here,
    -- spanning three, two and one bytes, with the surrounding text untouched.
    decodeUtf8_replaceEmitsOneCharacterPerMaximalSubpart: (ut) ->
      ut\assertItemsEqual unicode.decodeUtf8(SUBPARTS_OF_DECREASING_LENGTH, Replace),
        {0x61, REPLACEMENT, REPLACEMENT, REPLACEMENT, 0x62}

    -- The standard's own illustration of the rule: a truncated character is one subpart however many
    -- bytes are missing, because every byte present could still have been part of the whole sequence.
    decodeUtf8_replaceSpansATruncatedCharacterWithOneReplacement: (ut) ->
      ut\assertItemsEqual unicode.decodeUtf8(TRUNCATED_EMOJI, Replace), {REPLACEMENT}
      ut\assertEquals unicode.getCharWidth(TRUNCATED_EMOJI, 1, Replace), 3

    -- The point of the maximal subpart: a lead byte claiming more than it can have must not consume
    -- what follows. Advancing by its claimed width instead would drop the "A" entirely.
    decodeUtf8_replaceResynchronizesWithoutSwallowingTheNextCharacter: (ut) ->
      ut\assertItemsEqual unicode.decodeUtf8(OVERLONG_LEAD_THEN_ASCII, Replace),
        {REPLACEMENT, REPLACEMENT, 0x41}

    decodeUtf8_replaceSubstitutesForEveryIllFormedSequence: (ut) ->
      ut\assertItemsEqual unicode.decodeUtf8(OVERLONG_SLASH, Replace), {REPLACEMENT, REPLACEMENT}
      ut\assertItemsEqual unicode.decodeUtf8(ENCODED_SURROGATE, Replace),
        {REPLACEMENT, REPLACEMENT, REPLACEMENT}
      ut\assertItemsEqual unicode.decodeUtf8(STRAY_CONTINUATION, Replace), {REPLACEMENT}

    -- a lead byte whose tail simply runs out is one subpart, not one per missing byte
    decodeUtf8_replaceSpansATruncatedTailWithASingleCharacter: (ut) ->
      ut\assertItemsEqual unicode.decodeUtf8(TRUNCATED, Replace), {REPLACEMENT}

    decodeUtf8_replaceLeavesWellFormedTextAlone: (ut) ->
      text = "a#{UMLAUT}#{IDEOGRAPH_ONE}#{EMOJI}"
      ut\assertItemsEqual unicode.decodeUtf8(text, Replace), unicode.decodeUtf8 text, Strict

    -- a substituted character covers the bytes it stands for, so character boundaries stay aligned
    iterateChars_replaceYieldsTheBytesEachSubstitutionCovers: (ut) ->
      byteCounts = [#char for char in unicode.iterateChars OVERLONG_LEAD_THEN_ASCII, Replace]
      ut\assertItemsEqual byteCounts, {1, 1, 1}
      ut\assertItemsEqual [#char for char in unicode.iterateChars TRUNCATED, Replace], {2}

    getCharWidth_replaceReportsTheSubstitutedSpan: (ut) ->
      ut\assertEquals unicode.getCharWidth(TRUNCATED, 1, Replace), 2
      ut\assertEquals unicode.getCharWidth(OVERLONG_LEAD_THEN_ASCII, 1, Replace), 1

    getCodePoint_replaceAnswersWithTheReplacementCharacter: (ut) ->
      ut\assertEquals unicode.getCodePoint(OVERLONG_SLASH, 1, Replace), REPLACEMENT
      ut\assertEquals unicode.getCodePoint(EMOJI, 1, Replace), 0x1F600

    iterateChars_yieldsEachCharacterWithItsIndex: (ut) ->
      characters, indices = {}, {}
      for character, index in unicode.iterateChars "a#{UMLAUT}#{EMOJI}"
        characters[#characters + 1] = character
        indices[#indices + 1] = index
      ut\assertItemsEqual characters, {"a", UMLAUT, EMOJI}
      ut\assertItemsEqual indices, {1, 2, 3}

    iterateChars_yieldsNothingForAnEmptyString: (ut) ->
      count = 0
      count += 1 for _ in unicode.iterateChars ""
      ut\assertZero count

    -- validating up front means the iteration itself never has to fail partway through
    iterateChars_strictRejectsBeforeIterating: (ut) ->
      iterator, err = unicode.iterateChars "a#{OVERLONG_SLASH}", Strict
      ut\assertNil iterator
      ut\assertMatches err, "not valid UTF%-8"

    getLength_countsCharactersNotBytes: (ut) ->
      ut\assertEquals unicode.getLength("a#{UMLAUT}#{EMOJI}"), 3
      ut\assertZero unicode.getLength ""

    getLength_strictRejectsMalformedText: (ut) ->
      ut\assertNil unicode.getLength "a#{ENCODED_SURROGATE}", Strict

    encodeUtf8_encodesEachWidth: (ut) ->
      ut\assertEquals unicode.encodeUtf8({0x61, 0xFC, 0x4E00, 0x1F600}),
        "a#{UMLAUT}#{IDEOGRAPH_ONE}#{EMOJI}"

    encodeUtf8_encodesAnEmptyList: (ut) ->
      ut\assertEquals unicode.encodeUtf8({}), ""

    -- the contract the validation buys: nothing the encoder accepts can come back as ill-formed
    encodeUtf8_outputSurvivesAStrictDecode: (ut) ->
      codePoints = {0x00, 0x61, 0x7F, 0x80, 0xFC, 0x7FF, 0x800, 0x4E00, 0xFFFF, 0x10000, LAST_CODE_POINT}
      text = unicode.encodeUtf8 codePoints
      ut\assertItemsEqual unicode.decodeUtf8(text, Strict), codePoints

    encodeUtf8_rejectsCodePointsBeyondTheLastOne: (ut) ->
      text, err = unicode.encodeUtf8 {LAST_CODE_POINT + 1}
      ut\assertNil text
      ut\assertMatches err, "not an encodable code point"

    -- a surrogate is UTF-16's astral encoding, not a character, so UTF-8 may not carry one
    encodeUtf8_rejectsSurrogates: (ut) ->
      ut\assertNil unicode.encodeUtf8 {FIRST_LEAD_SURROGATE}
      ut\assertNil unicode.encodeUtf8 {LAST_TRAIL_SURROGATE}

    -- string.char would silently truncate a fraction and raise unhelpfully on a negative
    encodeUtf8_rejectsValuesThatAreNotCodePoints: (ut) ->
      ut\assertNil unicode.encodeUtf8 {-1}
      ut\assertNil unicode.encodeUtf8 {65.5}

    encodeUtf8_namesTheRejectedEntry: (ut) ->
      _, err = unicode.encodeUtf8 {0x41, 0x42, LAST_CODE_POINT + 1}
      ut\assertMatches err, "Entry 3"

    -- what separates the two decode modes: compatibility answers with values that are not code points
    encodeUtf8_rejectsWhatACompatibilityDecodeProduced: (ut) ->
      for malformed in *{BEYOND_LAST_CODE_POINT, STRAY_CONTINUATION, ENCODED_SURROGATE}
        codePoints = unicode.decodeUtf8 malformed, AegisubCompatibility
        text, err = unicode.encodeUtf8 codePoints
        ut\assertNil text
        ut\assertMatches err, "not an encodable code point"

    encodeUtf8_replaceSubstitutesWhatItCannotEncode: (ut) ->
      ut\assertEquals unicode.encodeUtf8({0x41, LAST_CODE_POINT + 1, 0x42}, Replace),
        "A#{unicode.encodeUtf8 {REPLACEMENT}}B"
      ut\assertEquals unicode.encodeUtf8({FIRST_LEAD_SURROGATE}, Replace),
        unicode.encodeUtf8 {REPLACEMENT}
      ut\assertEquals unicode.encodeUtf8({-1, 65.5}, Replace),
        unicode.encodeUtf8 {REPLACEMENT, REPLACEMENT}

    -- Aegisub has no encoder to be compatible with, so that mode encodes as Replace does
    encodeUtf8_compatibilitySubstitutesAsReplaceDoes: (ut) ->
      ut\assertEquals unicode.encodeUtf8({LAST_CODE_POINT + 1}, AegisubCompatibility),
        unicode.encodeUtf8 {REPLACEMENT}

    -- The round trip Replace exists to make total: any byte string decodes, and everything it decodes
    -- to re-encodes, so sanitizing corrupt text takes one pass and cannot fail.
    encodeUtf8_replaceCompletesTheRoundTripFromAnyBytes: (ut) ->
      for malformed in *{OVERLONG_SLASH, ENCODED_SURROGATE, TRUNCATED, BEYOND_LAST_CODE_POINT,
        SUBPARTS_OF_DECREASING_LENGTH, OVERLONG_LEAD_THEN_ASCII}
        sanitized = unicode.encodeUtf8 unicode.decodeUtf8(malformed, Replace), Replace
        ut\assertNotNil sanitized
        ut\assertNotNil unicode.decodeUtf8 sanitized, Strict

    encodeUtf16_replaceSubstitutesWhatItCannotEncode: (ut) ->
      ut\assertItemsEqual unicode.encodeUtf16({0x41, LAST_CODE_POINT + 1}, Replace), {0x41, REPLACEMENT}
      ut\assertItemsEqual unicode.encodeUtf16({FIRST_LEAD_SURROGATE}, Replace), {REPLACEMENT}

    encodeUtf16_leavesBmpCodePointsAsSingleUnits: (ut) ->
      units, offsets = unicode.encodeUtf16 {0x41, 0xFC}
      ut\assertItemsEqual units, {0x41, 0xFC}
      ut\assertItemsEqual offsets, {0, 1}

    -- an astral code point becomes the surrogate pair a UTF-16 API expects
    encodeUtf16_splitsAstralCodePointsIntoSurrogatePairs: (ut) ->
      units, offsets = unicode.encodeUtf16 {0x41, 0x1F600, 0x42}
      ut\assertItemsEqual units, {0x41, 0xD83D, 0xDE00, 0x42}
      ut\assertItemsEqual offsets, {0, 1, 3}

    encodeUtf16_handlesTheFirstAndLastAstralCodePoints: (ut) ->
      ut\assertItemsEqual unicode.encodeUtf16({0x10000}), {0xD800, 0xDC00}
      ut\assertItemsEqual unicode.encodeUtf16({LAST_CODE_POINT}), {0xDBFF, 0xDFFF}

    encodeUtf16_roundTripsWhatDecodingProduced: (ut) ->
      units = unicode.encodeUtf16 unicode.decodeUtf8 "a#{EMOJI}b", Strict
      ut\assertItemsEqual units, {0x61, 0xD83D, 0xDE00, 0x62}

    -- an unpaired surrogate unit would be the result, which is what a UTF-16 API must never be handed
    encodeUtf16_rejectsValuesThatAreNotCodePoints: (ut) ->
      units, err = unicode.encodeUtf16 {LAST_CODE_POINT + 1}
      ut\assertNil units
      ut\assertMatches err, "not an encodable code point"
      ut\assertNil unicode.encodeUtf16 {FIRST_LEAD_SURROGATE}
      ut\assertNil unicode.encodeUtf16 {-1}

    decodeUtf16_decodesASurrogatePair: (ut) ->
      ut\assertItemsEqual unicode.decodeUtf16({0x61, 0xD83D, 0xDE00}), {0x61, 0x1F600}

    decodeUtf16_strictRejectsAnUnpairedSurrogate: (ut) ->
      codePoints, err = unicode.decodeUtf16 {0xD83D, 0x41}, Strict
      ut\assertNil codePoints
      ut\assertMatches err, "not valid UTF%-8"

    -- a non-strict decode substitutes, so the conversion completes rather than failing
    decodeUtf16_compatibilitySubstitutesForAnUnpairedSurrogate: (ut) ->
      codePoints = unicode.decodeUtf16 {0xD83D, 0x41}, AegisubCompatibility
      ut\assertItemsEqual codePoints, {unicode.REPLACEMENT_CODE_POINT, 0x41}

    decodeMode_rejectsAValueOutsideTheEnum: (ut) ->
      ut\assertErrorMsgMatches (-> unicode.decodeUtf8 "a", 99), {}, "Invalid value"

    getCharWidth_rejectsANonString: (ut) ->
      ut\assertError unicode.getCharWidth, 42
  }
