-- Pins the declaration rewriting behind ffi-binding — prefixing, asm aliasing, identifier-boundary
-- safety — and the bind contract for missing libraries and repeated binds.
-- Called from test.moon as: (controls\requireTest "ffi-binding")!
->
  ffi = require "ffi"
  ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"
  {:DEPCTRL_SHORT_NAME} = require "l0.DependencyControl.Constants"

  rewrite = ffiBinding.__rewriteDeclarations

  {
    _description: "The collision-proof FFI declaration helper."

    rewrite_prefixesAStructEverywhereItAppears: (ut) ->
      rewritten = rewrite "typedef struct { long x; } Point; int measure(Point* p);", {"Point"}, {"measure"}
      ut\assertNotNil rewritten\find "} #{DEPCTRL_SHORT_NAME}Point;", 1, true
      ut\assertNotNil rewritten\find "(#{DEPCTRL_SHORT_NAME}Point* p)", 1, true

    rewrite_aliasesAFunctionToItsRealSymbol: (ut) ->
      rewritten = rewrite "void* CreateThing(int flags);", {}, {"CreateThing"}
      ut\assertNotNil rewritten\find "#{DEPCTRL_SHORT_NAME}CreateThing(int flags) __asm__(\"CreateThing\");", 1, true

    -- FcPatternCreate must keep its middle intact while FcPattern alone is rewritten
    rewrite_neverRewritesANameInsideALongerIdentifier: (ut) ->
      rewritten = rewrite "typedef struct FcPattern FcPattern; FcPattern* FcPatternCreate(void);",
        {"FcPattern"}, {"FcPatternCreate"}
      ut\assertNotNil rewritten\find "#{DEPCTRL_SHORT_NAME}FcPattern* #{DEPCTRL_SHORT_NAME}FcPatternCreate(void)", 1, true
      ut\assertNil rewritten\find "#{DEPCTRL_SHORT_NAME}#{DEPCTRL_SHORT_NAME}", 1, true

    rewrite_handlesAParameterListSpanningLines: (ut) ->
      rewritten = rewrite "int measure(int a,\n  int b);", {}, {"measure"}
      ut\assertNotNil rewritten\find "__asm__(\"measure\");", 1, true

    rewrite_reportsAListedFunctionTheDeclarationsLack: (ut) ->
      ut\assertErrorMsgMatches (-> rewrite "int other(void);", {}, {"missing"}), {},
        "'missing' is listed but not found"

    rewrite_reportsAListedStructTheDeclarationsLack: (ut) ->
      ut\assertErrorMsgMatches (-> rewrite "int fn(void);", {"Missing"}, {"fn"}), {},
        "'Missing' is listed but not found"

    rewrite_reportsAFunctionDeclaredTwice: (ut) ->
      ut\assertErrorMsgMatches (-> rewrite "int fn(void); int fn(int a);", {}, {"fn"}), {},
        "declared 2 times"

    -- probing ICU-style version-suffixed symbols declares one candidate at a time, each needing its
    -- own collision-proof name
    declare_declaresOneFunctionAtATimeUnderDistinctNames: (ut) ->
      _, first = ffiBinding.declare "int FfiBindingTestProbe_74(void);", nil, {"FfiBindingTestProbe_74"}
      _, second = ffiBinding.declare "int FfiBindingTestProbe_75(void);", nil, {"FfiBindingTestProbe_75"}
      ut\assertNotEquals first.FfiBindingTestProbe_74, second.FfiBindingTestProbe_75
      ut\assertMatches first.FfiBindingTestProbe_74, "FfiBindingTestProbe_74$"

    declare_toleratesTheSameDeclarationAgain: (ut) ->
      declarations = "typedef struct { int x; } FfiBindingTestDeclareTwice;"
      ffiBinding.declare declarations, {"FfiBindingTestDeclareTwice"}
      types = ffiBinding.declare declarations, {"FfiBindingTestDeclareTwice"}
      ut\assertEquals ffi.sizeof(types.FfiBindingTestDeclareTwice!), ffi.sizeof "int"

    -- symbols already linked into the process bind through ffi.C rather than a loaded library
    bind_bindsFromAGivenNamespace: (ut) ->
      binding = ffiBinding.bind {
        namespace: ffi.C
        functions: {"strlen"}
        declarations: "size_t strlen(const char* s);"
      }
      ut\assertTrue binding.isAvailable
      ut\assertEquals tonumber(binding.functions.strlen "four"), 4

    bind_declaresTypesWithoutALibrary: (ut) ->
      binding = ffiBinding.bind {
        declarations: "typedef struct { long x; long y; } FfiBindingTestPoint;"
        structs: {"FfiBindingTestPoint"}
      }
      ut\assertTrue binding.isAvailable
      ut\assertNil binding.functions
      point = binding.types.FfiBindingTestPoint!
      point.x = 42
      ut\assertEquals tonumber(point.x), 42
      ut\assertEquals ffi.sizeof(point), 2 * ffi.sizeof "long"

    -- reloading the declaring module binds the same declarations again, which must not raise
    bind_bindsTheSameDeclarationsTwice: (ut) ->
      args = {
        declarations: "typedef struct { int value; } FfiBindingTestRepeat;"
        structs: {"FfiBindingTestRepeat"}
      }
      first = ffiBinding.bind args
      second = ffiBinding.bind args
      ut\assertEquals ffi.sizeof(second.types.FfiBindingTestRepeat!), ffi.sizeof first.types.FfiBindingTestRepeat!

    bind_reportsAMissingLibraryUnavailable: (ut) ->
      binding = ffiBinding.bind {
        declarations: "int FfiBindingTestNothing(void);"
        functions: {"FfiBindingTestNothing"}
        library: {"no-such-library-anywhere", "also-not-a-library"}
      }
      ut\assertFalse binding.isAvailable
      ut\assertNil binding.functions

    bind_bindsARealLibraryFunction: (ut) ->
      local binding
      if ffi.os == "Windows"
        binding = ffiBinding.bind {
          declarations: "unsigned long GetTickCount(void);"
          functions: {"GetTickCount"}
          library: "kernel32"
        }
        ut\assertTrue binding.isAvailable
        ut\assertGreaterThan tonumber(binding.functions.GetTickCount!), 0
      else
        binding = ffiBinding.bind {
          declarations: "double cos(double x);"
          functions: {"cos"}
          library: "m"
        }
        ut\assertTrue binding.isAvailable
        ut\assertAlmostEquals binding.functions.cos(0), 1

    -- a caller's own bare declaration resolves through the bound table, which FileLock relies on
    bind_fallsThroughToTheLibraryForUnlistedNames: (ut) ->
      local binding, probed
      if ffi.os == "Windows"
        binding = ffiBinding.bind {
          declarations: "unsigned long GetCurrentThreadId(void);"
          functions: {"GetCurrentThreadId"}
          library: "kernel32"
        }
        pcall ffi.cdef, "unsigned long GetCurrentProcessId(void);"
        probed = tonumber binding.functions.GetCurrentProcessId!
      else
        binding = ffiBinding.bind {
          declarations: "double sin(double x);"
          functions: {"sin"}
          library: "m"
        }
        pcall ffi.cdef, "double fabs(double x);"
        probed = binding.functions.fabs -3
      ut\assertNotNil probed
      ut\assertGreaterThan probed, 0
  }
