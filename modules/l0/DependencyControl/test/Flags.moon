-- Flags tests: named bits meant to be combined, against the Enum semantics they deliberately part from.
-- Called from test.moon as: (controls\requireTest "Flags")!
->
  Flags = require "l0.DependencyControl.Flags"
  Enum = require "l0.DependencyControl.Enum"

  -- the OS/2 fsSelection bits, which are what prompted the type
  selection = -> Flags "TestSelection", {
    Italic: 0x001
    Bold: 0x020
    Regular: 0x040
    UseTypoMetrics: 0x080
    Oblique: 0x200
  }

  -- the OS/2 fsType shape: one exclusive licensing level beside two free bits
  withGroup = -> Flags "TestFsType", {
    {
      RestrictedLicense: 0x002
      PreviewAndPrint: 0x004
      Editable: 0x008
    }
    NoSubsetting: 0x100
  }

  {
    _description: "Tests for the Flags class providing combinable named bits over Enum."

    new_membersReadOffTheTypeAsOnAnEnum: (ut) ->
      flags = selection!
      ut\assertEquals flags.Bold, 0x020
      ut\assertEquals flags.UseTypoMetrics, 0x080

    new_maskCoversEveryMemberDeclared: (ut) ->
      ut\assertEquals selection!.mask, 0x2E1

    new_rejectsAValuePastThirtyTwoBits: (ut) ->
      ut\assertErrorMsgMatches (-> Flags "TooWide", {Huge: 0x100000000}), {}, "32 bits"

    new_rejectsAMemberNamedAfterAFlagsBuiltIn: (ut) ->
      ut\assertErrorMsgMatches (-> Flags "Clashing", {toList: 1}), {}, "reserved"
      ut\assertErrorMsgMatches (-> Flags "Clashing", {mask: 1}), {}, "reserved"

    -- Enum's own reserved names stay reserved, the type being one
    new_rejectsAMemberNamedAfterAnEnumBuiltIn: (ut) ->
      ut\assertErrorMsgMatches (-> Flags "Clashing", {describe: 1}), {}, "reserved"

    -- combining

    combine_takesMemberNamesAndBitsAlike: (ut) ->
      flags = selection!
      ut\assertEquals flags\combine("Bold", "Italic"), 0x021
      ut\assertEquals flags\combine(flags.Bold, "Italic"), 0x021
      ut\assertEquals flags\combine!, 0

    combine_rejectsAnUndefinedMemberName: (ut) ->
      ut\assertErrorMsgMatches (-> selection!\combine "Nope"), {}, "defines no member"

    clear_takesTheMembersOutAndLeavesTheRest: (ut) ->
      flags = selection!
      ut\assertEquals flags\clear(flags\combine("Bold", "Italic"), "Bold"), 0x001

    toggle_flipsTheMembersGiven: (ut) ->
      flags = selection!
      ut\assertEquals flags\toggle(0x020, "Bold"), 0
      ut\assertEquals flags\toggle(0x020, "Italic"), 0x021

    -- reading

    has_readsOneMemberOutOfACombination: (ut) ->
      flags = selection!
      value = flags\combine "Bold", "UseTypoMetrics"
      ut\assertTrue flags\has value, "UseTypoMetrics"
      ut\assertTrue flags\has value, flags.Bold
      ut\assertFalse flags\has value, "Italic"

    toList_namesEveryMemberHeldInDeclarationOrder: (ut) ->
      flags = selection!
      held = flags\toList flags\combine "UseTypoMetrics", "Italic"
      ut\assertEquals #held, 2
      ut\assertTrue held[1] == "Italic" or held[2] == "Italic"
      ut\assertEquals #flags\toList(0), 0

    -- a member standing for a combination is held whenever all of its bits are
    toList_includesACompositeMemberAlongsideItsParts: (ut) ->
      flags = Flags "TestAccess", {Read: 0x1, Write: 0x2, ReadWrite: 0x3}
      held = {key, true for key in *flags\toList 0x3}
      ut\assertTrue held.Read
      ut\assertTrue held.Write
      ut\assertTrue held.ReadWrite

    describe_joinsTheMembersHeld: (ut) ->
      flags = selection!
      ut\assertEquals flags\describe(flags\combine "Italic", "Bold"), "Italic|Bold"
      ut\assertEquals flags\describe(0), "0"
      ut\assertEquals flags\describe(0x020, ((key) -> key\lower!), ", "), "bold"

    -- validation, which is where Flags parts from Enum
    validate_acceptsAnyCombinationOfMembers: (ut) ->
      flags = selection!
      ut\assertTrue flags\validate flags\combine "Bold", "Italic", "Oblique"
      ut\assertTrue flags\validate 0
      ut\assertTrue flags\validate flags.mask

    validate_rejectsABitNoMemberDefines: (ut) ->
      valid, err = selection!\validate 0x400, "fsSelection"
      ut\assertNil valid
      ut\assertMatches err, "fsSelection"
      ut\assertMatches err, "0x400"

    validate_rejectsWhatIsNotANumber: (ut) ->
      valid, err = selection!\validate "Bold"
      ut\assertNil valid
      ut\assertMatches err, "expected a number"

    -- an Enum of the same members would reject the combination, which is the whole difference
    validate_partsFromTheEnumOfTheSameMembers: (ut) ->
      asEnum = Enum "TestSelectionEnum", {Italic: 0x001, Bold: 0x020}
      ut\assertNil asEnum\validate 0x021
      ut\assertTrue selection!\validate 0x021

    -- the top bit still reads unsigned, where a bit operation would hand back a negative
    combine_keepsAValuePastTheSignBitUnsigned: (ut) ->
      flags = Flags "TestHigh", {Low: 0x1, Top: 0x80000000}
      value = flags\combine "Low", "Top"
      ut\assertEquals value, 0x80000001
      ut\assertTrue flags\has value, "Top"
      ut\assertEquals flags\clear(value, "Low"), 0x80000000

    -- exclusive groups

    -- a nested table names members that exclude each other; they still read off the type flat
    new_nestedGroupMembersReadFlat: (ut) ->
      flags = withGroup!
      ut\assertEquals flags.Editable, 0x008
      ut\assertEquals flags.NoSubsetting, 0x100
      ut\assertEquals flags.mask, 0x10E

    validate_acceptsOneMemberOfAGroupBesideFreeBits: (ut) ->
      flags = withGroup!
      ut\assertTrue flags\validate 0x008
      ut\assertTrue flags\validate flags\combine "Editable", "NoSubsetting"
      ut\assertTrue flags\validate 0

    validate_rejectsTwoMembersOfOneGroup: (ut) ->
      valid, err = withGroup!\validate 0x00A, "fsType"
      ut\assertNil valid
      ut\assertMatches err, "fsType"
      ut\assertMatches err, "exclude each other"

    combine_rejectsTwoMembersOfOneGroup: (ut) ->
      ut\assertErrorMsgMatches (-> withGroup!\combine "Editable", "RestrictedLicense"), {},
        "exclude each other"

    -- a member of no bits is held by every value, so counting it would make every value clash
    validate_ignoresAZeroMemberInAGroup: (ut) ->
      flags = Flags "TestAccess", {
        {Read: 0, Write: 1, ReadWrite: 2}
        CloseOnExec: 0x80
      }
      ut\assertTrue flags\validate flags\combine "Write", "CloseOnExec"
      ut\assertTrue flags\validate 0
      ut\assertNil flags\validate 0x3

    -- taking bits back out is no violation, whatever group they belong to
    clear_takesTwoMembersOfOneGroupOut: (ut) ->
      ut\assertEquals withGroup!\clear(0x00A, "Editable", "RestrictedLicense"), 0

    toggle_flipsTwoMembersOfOneGroup: (ut) ->
      ut\assertEquals withGroup!\toggle(0, "Editable", "RestrictedLicense"), 0x00A

    -- construction options

    new_takesALoggerOnItsOwnOrInAnOptionsTable: (ut) ->
      thrown = 0
      stub =
        log: ->
        error: (template) =>
          thrown += 1
          error template, 0

      bare = Flags "Bare", {X: 1}, stub
      wrapped = Flags "Wrapped", {X: 1}, {logger: stub}
      ut\assertEquals bare.X, 1
      ut\assertEquals wrapped.X, 1

      -- an invalid member read goes through the logger either way
      ut\assertError -> bare.Nope
      ut\assertError -> wrapped.Nope
      ut\assertEquals thrown, 2

    -- inherited from Enum and still in force
    flags_areImmutable: (ut) ->
      flags = selection!
      ut\assertError -> flags.Bold = 1

    flags_rejectAnUndefinedMemberRead: (ut) ->
      flags = selection!
      ut\assertError -> flags.Nope
  }
