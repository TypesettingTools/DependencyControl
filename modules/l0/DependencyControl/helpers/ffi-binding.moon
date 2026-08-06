-- LuaJIT keeps one C declaration namespace per Lua state, so two libraries declaring the same
-- function or struct fail whichever loads second — silently where the cdef is pcall'd, then
-- cryptically at call time. Every declaration made here is rewritten to a DepCtrl-prefixed name
-- before it reaches ffi.cdef, with functions aliased back to their real symbols, so declarations
-- from a script sharing the state never clash with these in either direction.

ffi = require "ffi"
{:DEPCTRL_SHORT_NAME} = require "l0.DependencyControl.Constants"

msgs = {
  rewriteDeclarations: {
    functionNotDeclared: "The function '%s' is listed but not found in the declarations."
    functionDeclaredTwice: "The function '%s' is declared %d times; declare it once."
    structNotDeclared: "The struct '%s' is listed but not found in the declarations."
  }
  declare: {
    missingDeclarations: "A binding needs its C declarations as a string."
  }
}

-- prevent matching an identifier in a longer one of which it is a substring, e.g. "CreateFile" in "CreateFileW"
FRONTIER_PATTERN_BEFORE = "%f[%w_]"
FRONTIER_PATTERN_AFTER = "%f[^%w_]"

---Rewrites bare C declarations onto prefixed names, aliasing functions to their real symbols.
---Each listed function must be declared exactly once, as `type name(params);` with balanced
---parentheses; each listed struct at least once.
---@param declarations string The C declarations, using the bare names.
---@param structs string[] Struct and typedef names to prefix.
---@param functions string[] Function names to prefix and alias.
---@return string rewritten The declarations with every listed name prefixed.
---@return table<string, string> prefixedNames The prefixed name each bare name became.
rewriteDeclarations = (declarations, structs, functions) ->
  prefixedNames = {}

  -- functions first, while the bare name still ends the declaration the asm alias attaches to
  for name in *functions
    prefixedNames[name] = "#{DEPCTRL_SHORT_NAME}#{name}"
    declared = 0
    declarations = declarations\gsub "#{FRONTIER_PATTERN_BEFORE}#{name}(%s*%b())%s*;", (params) ->
      declared += 1
      "#{prefixedNames[name]}#{params} __asm__(\"#{name}\");"
    assert declared > 0, msgs.rewriteDeclarations.functionNotDeclared\format name
    assert declared == 1, msgs.rewriteDeclarations.functionDeclaredTwice\format name, declared

  for name in *structs
    prefixedNames[name] = "#{DEPCTRL_SHORT_NAME}#{name}"
    rewritten, count = declarations\gsub "#{FRONTIER_PATTERN_BEFORE}#{name}#{FRONTIER_PATTERN_AFTER}", prefixedNames[name]
    assert count > 0, msgs.rewriteDeclarations.structNotDeclared\format name
    declarations = rewritten

  return declarations, prefixedNames

---Declares C API entities under prefixed names, tolerating an identical earlier declaration so a
---declaring module reloads cleanly.
---@param declarations string C declarations using the bare names.
---@param structs? string[] Struct and typedef names declared, prefixed everywhere they appear.
---@param functions? string[] Function names declared, prefixed and aliased to the real symbols.
---@return table<string, ffi.ctype*> types A constructor for each declared struct, keyed by its bare name.
---@return table<string, string> prefixedNames The declared name each bare name became.
declare = (declarations, structs = {}, functions = {}) ->
  assert type(declarations) == "string", msgs.declare.missingDeclarations
  rewritten, prefixedNames = rewriteDeclarations declarations, structs, functions

  -- Prefixed names can only ever collide with an identical earlier declaration, which reloading the
  -- declaring module produces; everything is then already declared. Any other failure is a defect in
  -- the declarations and raises.
  declared, err = pcall ffi.cdef, rewritten
  assert declared or err\find("attempt to redefine", 1, true), err

  types = {name, ffi.typeof prefixedNames[name] for name in *structs}
  return types, prefixedNames

---What a binding declares and which library provides it.
---@class FfiBindingArgs
---@field declarations string C declarations using the bare names, one declaration per statement. Function parameter lists must use balanced parentheses only, so a function-pointer parameter needs a typedef.
---@field library? string|string[] Library to load, or names to try in order with versioned sonames first.
---@field namespace? ffi.namespace* An already-reachable namespace to bind from, `ffi.C` for symbols linked into the process; when given, no library is loaded. Omit both this and `library` for a declarations-only binding.
---@field structs? string[] Struct and typedef names declared, prefixed everywhere they appear.
---@field functions? string[] Function names declared, prefixed and aliased to the real symbols.

---A declared and loaded C API.
---@class FfiBoundLibrary
---@field isAvailable boolean Whether the library loaded, or true for a declarations-only binding.
---@field functions table<string, ffi.cdata*>? The bound calls keyed by their real names; a name whose symbol the library lacks is absent, and unknown keys resolve through the library so a caller's own declarations work too. Nil while unavailable or declarations-only.
---@field types table<string, ffi.ctype*> A constructor for each declared struct, keyed by its bare name.
---@field prefixedNames table<string, string> The declared name each bare name became, for composing derived type strings such as pointer or array forms.

---Utilities for reaching C APIs through collision-proof prefixed declarations.
---@class FfiBinding
Binding = {
  ---Declares a C API under prefixed names and loads the library providing it.
  ---Binding the same declarations again is a no-op, so a module using this reloads cleanly.
  ---@param args FfiBindingArgs What to declare and load.
  ---@return FfiBoundLibrary binding The declared API, with `isAvailable` reporting whether it loaded.
  bind: (args) ->
    structs, functions = args.structs or {}, args.functions or {}
    types, prefixedNames = declare args.declarations, structs, functions

    libraryNames = args.library
    libraryNames = {libraryNames} if type(libraryNames) == "string"

    namespace = args.namespace
    if not namespace and libraryNames
      for name in *libraryNames
        loaded, library = pcall ffi.load, name
        if loaded
          namespace = library
          break
      return {isAvailable: false, :types, :prefixedNames} unless namespace

    local boundFunctions
    if namespace
      -- unknown keys fall through to the library, so a caller's own bare declarations — extra
      -- functions it declares itself — keep resolving through this table
      boundFunctions = setmetatable {}, __index: namespace
      for name in *functions
        bound, symbol = pcall -> namespace[prefixedNames[name]]
        boundFunctions[name] = symbol if bound

    return {
      isAvailable: true
      functions: boundFunctions
      :types
      :prefixedNames
    }

  ---Declares without loading anything, for a binding that resolves its symbols itself — probing
  ---version-suffixed names, one declaration at a time — with the same collision-proof prefixing.
  ---@param declarations string C declarations using the bare names.
  ---@param structs? string[] Struct and typedef names declared, prefixed everywhere they appear.
  ---@param functions? string[] Function names declared, prefixed and aliased to the real symbols.
  ---@return table<string, ffi.ctype*> types A constructor for each declared struct, keyed by its bare name.
  ---@return table<string, string> prefixedNames The declared name each bare name became.
  declare: declare

  ---The rewriting behind bind, reachable for its unit tests.
  ---@private
  ---@param declarations string The C declarations, using the bare names.
  ---@param structs string[] Struct and typedef names to prefix.
  ---@param functions string[] Function names to prefix and alias.
  ---@return string rewritten The declarations with every listed name prefixed.
  ---@return table<string, string> prefixedNames The prefixed name each bare name became.
  __rewriteDeclarations: rewriteDeclarations
}

return Binding
