# Agent guidelines for DependencyControl

## Annotations

Write annotations to inform callers: what the method does, what to pass in, what comes back, and any side effects worth knowing about. Do not write implementation reports, session history, or rationale for design decisions made in a prior conversation — those belong in commit messages or PR descriptions. The governing test for every comment, doc or inline, is the cold-reader test in [Inline comments](#inline-comments): if it only makes sense given our discussion, it doesn't belong in the code.

A comment is allowed to mention a non-obvious constraint or design choice *if it directly affects how callers use the API*. Example: "Automation scripts have their tests registered and updates scheduled when they call `registerMacros` through DependencyControl." That is a behavioral contract. "This replaces the old per-environment scheduling that caused lock contention" is not.

### Length and altitude

A doc comment is the **contract**, not a paraphrase of the body: what the caller passes, what comes back, and any side effect — at the highest altitude that still informs. This is a separate failure mode from narration: a description can be free of design rationale and *still* be wrong for being a verbose restatement of the code.

- **Default to one line.** If one line says it, the method gets one line — no matter how long its body is. Add a second line only for a genuinely separate contract (a precondition, a side effect), never to pad.
- **Never restate the body.** "a required dependency errors with `-6`, an optional one returns `3`" is just the `if`/`else` in prose, and the `@return` already carries the codes. Describe the *outcome* a caller relies on, not the branches that produce it.
- **Stay inside this method.** Don't narrate what *another* method does ("(run acquires the lock first)"); state only the contract on this call ("the lock must already be held").
- **Every `@return` gets a description**, not just a type (the most-skipped mandatory rule). Resolve its apparent clash with "never restate the body" by dividing the labor: the summary states the method's purpose and any non-obvious behavior, and the `@return` states the concrete shape and edge conditions the summary omits, such as the nil case, ordering, or emptiness. For a trivial side-effect-free getter that genuinely leaves nothing to add, accept a little overlap. The `@return` is surfaced at call sites on its own, so a concise shape label earns its place even when it echoes the summary. What stays banned is padding either side with invented detail just to force a difference, or skipping the shape/edge detail when there *is* some.
- **Clustered punctuation is a smell**, in inline `--` comments as much as doc comments. No single mark is banned — parentheses, semicolons, colons, and em dashes are all fine on their own. But when they pile up in one sentence, the thought usually needs reorganizing. Watch for a semicolon nested inside a parenthetical (`(sorted; empty when none)`), stacked or back-to-back parentheticals, an em-dash aside dropped into a clause that already carries parens or a semicolon, a closing paren shoved against a semicolon (`(nil if unreachable); defaults…`), or a `label:` headline that hangs the explanation off a colon like a blog subhead (`next, not pairs: a subclass…`). The fix is one aside per sentence: split the rest into a clean clause or a second sentence.

### Identifier references in prose

Prefer natural language over backticked identifier names in a doc comment's prose. A `---@param feedUrl` is already declared, so the description reads "the given feed URL", not "`feedUrl`"; likewise drop reflexive "(see `otherMethod`)" pointers when a plain phrase carries the meaning. Reserve a backticked reference for when the exact name is what the caller acts on — a config key they set (`extraFeeds`, `fetchUntrustedFeeds`), an enum value the result equals, or a field they inspect (`stats.truncated`) — not as an echo of a declared parameter or a cross-link to another method.

- Prefer: Returns the namespaces of installed packages that effectively update from the given feed URL.
- Avoid: Returns the namespaces of installed packages that effectively update from `feedUrl` (see `getEffectiveSource`).

Why: prose reads more easily, and LuaCATS has no inline reference/link syntax — a backticked name is just literal text (and LuaLS doc highlighting doesn't render for `.moon` files anyway), so the backticks buy nothing but clutter.

### Naming

Name a method by what it is to the caller, not by a part-of-speech rule:

- **Commands** (do work, have effects) take a **verb**: `reportNoSuitablePackage`, `getEffectiveSource`, `persistSource`.
- **Value producers** — constructors, converters, selectors, predicates — may lead with a preposition or copula that signals the transformation or relationship: `toString`, `fromJSON`, `withoutInstall`, `withTestExports`, `atIndex`, `isBlocked`, `hasTeardown`.

The one hard ban: a **bare noun for a method that acts** — `failures`, `noSuitablePackage` read as fields, not operations. Litmus: read the name as a field access (`obj.name`); if the method does work but the name looks like stored data, rename it.

### LuaCATS / LuaLS style — always

Use [LuaCATS](https://github.com/LuaLS/lua-language-server/wiki/Annotations) for all doc comments.
Do **not** use _ldoc_, even though it appears in older parts of the codebase.

| ldoc (never)                     | LuaCATS (always)                          |
|----------------------------------|-------------------------------------------|
| `-- @tparam string x desc`       | `---@param x string desc`                 |
| `-- @treturn boolean`            | `---@return boolean`                      |
| `-- @classmod Foo`               | `---@class Foo`                           |
| `-- @param[opt] x`               | `---@param x? type`                       |

Always document every parameter and return value. Use `---@param name? type` for optional params.
Class-level docs go on a `---@class` line immediately before the class definition.

### Enum-typed values

**Define new enumerated sets with the DependencyControl `Enum` class** (`Enum "Name", {Key: value}`), not a plain Lua table. The `Enum` class gives immutability and value/key reverse lookup. (`Common.ScriptType`/`RecordType` were migrated to string-valued Enums; the only bare lookup tables left are deliberate presentation maps — dialog label/glyph tables and `Common.terms` — which are not value domains.)

When a parameter, field, or return holds a value from a DependencyControl `Enum` (e.g. `Common.ScriptType` or a band/mode enum), give it a named LuaCATS type instead of annotating it as a bare `integer`/`string` with a prose hint. `Enum` instances are built at runtime via `Enum "Name", {...}`, so LuaLS can't infer their members and `---@enum` (which needs a literal table) doesn't apply — declare an `---@alias` with one `---| <value> # <Key>: <description>` line per member directly above the `Enum`, and reference that name in annotations. Keep the per-member descriptions in the alias (single source of truth) and leave the runtime table bare:

```moon
---@alias UpdaterTrustBand
---| 1 # DeclaredDirect: the declared/own feed, trusted, offering the module by name
---| 2 # TrustedDirect: another trusted feed, offering the module by name
TrustBand = Enum "UpdaterTrustBand", {
    DeclaredDirect: 1
    TrustedDirect:  2
}

---@param band UpdaterTrustBand
```

### Inline comments

Use inline `--` comments only when the **why** is non-obvious: a hidden constraint, a subtle invariant, a language-level gotcha. Never describe *what* the code does — well-named identifiers already do that — nor restate what's obvious at a glance, like that `@base` is the method table or that a setter parses its argument.

**Litmus test — write for a reader who has never seen our conversation.** Before keeping a comment, ask: does it make sense to someone reading the file cold, with no access to our chat? A comment must describe the code *as it is* — a constraint it relies on or a hazard it guards against. It must **not** justify the implementation by comparing it to an alternative, another construct, or a previous version — that "why this and not that?" only exists in our discussion. If you want to explain a design decision, tell me in chat or put it in the commit message; never in the code.

Delete on sight any comment built on these tells (they signal you're narrating a decision, not documenting behavior): *"unlike …"*, *"rather than / instead of …"*, *"we now / no longer / used to …"*, *"this is better / cleaner because …"*, *"chosen / done this way so that …"*, *"moved here …"*.

```moon
-- GOOD — states a constraint the code actually relies on; stands on its own:
-- intervals are half-open [min, max), so the greatest satisfying version is max - 1
-- deep-copy so we don't mutate the shared default

-- BAD — narrates a decision/comparison from our discussion; meaningless to a cold reader:
-- a categorical enum (unlike the ordinal PromptThreshold), so string values rather than numbers
-- moved here so requirers don't have to unwrap anything
```

## File naming

Name a `.moon` file that defines and returns a single class after that class, in PascalCase (`FeedTrust.moon`, `Host.moon`). Name any other file — helpers that return a function or table, FFI shims, and the like — in kebab-case (`resolve-host.moon`, `ffi-posix.moon`). Test files mirror the name of what they test.

## Class or plain table

Reach for a MoonScript `class` only when its instances will carry state or behavior — when the type is genuinely meant to be constructed, now or in the foreseeable future. A module that is only a namespace of stateless functions (optionally alongside `Enum`s or constants) should be a plain table the file returns, not a class. A `class` advertises instantiability to every caller: it makes `Name(...)` a valid constructor and presents the type as constructable to tooling and readers, so using one for a never-constructed namespace hands library users the wrong mental model.

Default to a table, because the upgrade is one-directional. A table of functions upgrades to a class without breaking *callers*: a function invoked as `Mod.fn(args)` becomes a static method `@fn = (args) ->` with the same signature, and gaining a class merely *adds* a constructor. The reverse — retiring a class that callers already construct — breaks them. The upgrade is not entirely free, though. Turning a table into a class renames its file (`hash.moon` → `Hash.moon`) and its require path. But those are internal: a find-replace across our own requirers, not a published surface. So when instances are only a maybe-someday, ship the table now and upgrade if the need actually arrives.

Still give the table a type name with a plain `---@class Name` annotation on the value it returns; that is only a LuaCATS declaration, and with no constructor behind it nothing suggests the type is constructable. File naming follows from the decision (see [File naming](#file-naming)): PascalCase for a class file, kebab-case for a table module — so a stateless utility like `Hash` lives in `hash.moon`, even though that reads oddly next to a class file such as `FileOps.moon`. Some existing all-static classes predate this guidance; treat them as legacy to migrate, not precedent to copy.

A module's **public re-export** is the exception: it is a published surface, unlike its file and require path. Pin it to the name the module would carry as a class — PascalCase — even while the module is a table. Exporting `DependencyControl.Hash` rather than `.hash` costs nothing now and means a later table→class upgrade never renames the accessor. A lowercase export would force a breaking rename (or a permanent deprecated alias) exactly when you upgrade.

## MoonScript gotchas

**`or=` is a statement, not an expression.** A method whose entire body is `@field or= value` returns `nil`, not the assigned value. Always add an explicit `return @field` after a lazy-init `or=` when the caller expects a return value.

**`@@field arg` compiles to a method call, not a plain call.** Calling a value stored in a static field with `@@field arg` emits `self.__class:field(arg)` — a colon call that passes the class as an implicit first argument. When the field holds a constructor or plain function (e.g. a lazily-required class you want to call as `Cls(args)`), write `@@.field arg` (or bind it to a local first): `@@.field` emits plain `self.__class.field(arg)`. The same applies to instance fields: `@field arg` → `self:field(arg)`, vs `@.field arg` → `self.field(arg)`.

**A constructor's return value is discarded.** MoonScript's class `__call` always returns the freshly-built instance and ignores whatever `new` returns, so `Cls(...)` can never yield `(nil, err)` — a `return nil, code` inside `new` to signal "construction failed" is dead code. Validate *before* or *around* construction (e.g. in the factory/`addTask` that calls the constructor), not inside `new`.

**Compile-check before handoff.** A `.moon` syntax error makes Aegisub's loader fall through to a misleading "module not found". After any `.moon` edit, run:

```bash
moonc -p path/to/File.moon > /dev/null
```

Fix any parse errors before reporting the task done. Run the check on every changed file in the same turn, not just the last one edited.

## Private methods and the public API

Mark anything not meant to be called from outside its own class with `---@private` (LuaCATS). The language server then flags external `obj.method()` access while still allowing `@method`/`@@method` inside the class. Prefix the name with `__` as a visual signal.

A method is public if it's a safe, stable building block a caller outside its own class could reasonably use — **whether or not anything in this codebase calls it yet**. DependencyControl is a framework, so the test is: *would a third party building on it — say, a richer install/update UI than the Toolbox — want this?* Clean queries and utilities (`UpdateTask.getTrustedFeeds`/`getBlockedFeeds`, `Updater.isRunning`, `UpdateFeed.getModule`) stay public with no current caller. Mark `---@private` only genuine implementation details: fragile, context-dependent steps that operate on internal formats — the resolution/install pipeline, the built-in prompt flow, logging helpers. An existing external caller proves a method public; the absence of one does not prove it private. Never narrow a method that was public in a prior release — that's a silent breaking change. Tests are exempt — they deliberately drive internals through the stub-self pattern (`Class.method(fakeSelf, …)`), which is expected.

To **mock** an internal in a test, the test needs a field it can swap, so a mock-worthy dependency belongs in a `---@private` class field (`@@__dep`/`@__dep`), not a module-local upvalue (a `local` helper or `downloader = Downloader!`) that nothing outside the file can replace. The stub-self / class-stub patterns then swap the field. To merely **read** a private value or function from a test rather than replace it, use `withTestExports` (next section).

## Exposing internals for tests

Never add a test-only field or method to a module's public API (e.g. a class field) just so a test can reach it. Use the `UnitTestSuite` **test-export** helpers instead: `withTestExports` reveals a module's private internals to its tests and passes the module straight through, so it wraps the module's own `return`:

```moon
-- at the end of MyModule.moon
UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
return UnitTestSuite\withTestExports MyModule, {:somePrivate, :anotherPrivate}
```

The test file reads them straight from its own `require` — no routing through `Record\register` or the main test file:

```moon
MyModule = require "l0.DependencyControl.MyModule"
UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
{:somePrivate} = UnitTestSuite\getTestExports MyModule
```

Why this works: the exports are stashed on the module's metatable, so they're unreachable via normal `MyModule.x` indexing and stay off the public surface. Adding a non-metamethod key leaves the class's construction (`__call`) and inheritance (`__index`) metamethods intact, so requirers and `require` are unaffected — nothing needs to unwrap anything.

## Computed properties

A field whose read or write must run code — a derived value, or a stored value that needs conversion — is a computed property. Declare it with the `Accessors` module rather than hand-writing `__index`/`__newindex`, so the metatable manipulation lives in one audited place and each property is recorded on `Class.__accessors` for tooling. Mark the property in the class body and wire the class up once, immediately after the body (and, for a subclass, after the parent's `install` — a subclass inherits its parent's properties):

```moon
Accessors = require "l0.DependencyControl.Accessors"

class Record
  version: Accessors.property
    get: => @semanticVersion\toPacked!
    set: (value) => @semanticVersion = SemanticVersion.fromPacked SemanticVersion\toPacked value
  -- ...other methods...
Accessors.install Record
```

Omit `set` for a read-only property (a write raises). Two things follow from a property being computed rather than stored. A readable property **appears in `pairs(instance)`** with its getter value, like a raw field would — `install` adds a `__pairs` for this — so iterating runs each getter, and a getter that dereferences a nil backing field raises. So initialize the backing field before the property can be read (at the top of the constructor if the object is observable mid-construction, as records are via `createDummyRef`), and don't `pairs` a class's `__base` table, whose getters have no instance to run against. Separately, a property whose stored form differs from its runtime value needs explicit serialization: `Record.version` is a packed integer at runtime but a semver string in the config, so it's kept out of the generic `scriptFields` copy and converted by hand in `loadConfig`/`writeConfig`.

Annotate the property's type with a `---@field` on the `---@class`, not through the `property{…}` call — the accessor is invisible plumbing the type system shouldn't see. LuaCATS has no read-only field marker (`@field` scopes are only `private`/`protected`/`public`/`package`), so note a read-only property in its `@field` description and let `install` enforce it at runtime.

```moon
---@class Record
---@field semanticVersion SemanticVersion This record's version as a value object (the canonical store).
---@field version integer Packed-integer view over `semanticVersion`; assignable from a string, packed int, or instance.
```

## Module-private markers

A module-private sentinel or marker key — the tag `Accessors` uses to spot its property specs, the value `ut\skip` raises to abort a test — is a namespaced string built from the shared prefix, not a bare `{}` or a plain name: `"#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}SomeName"`. It stays collision-free across the shared global/config namespace while remaining inspectable and serializable.

## Dialog labels and dispatch

Never branch on a raw dialog label. A comparison like `switch btn when "Fetch/Discover"` or `btn == "Yes"` welds the visible wording to the control flow: rewording the caption silently breaks the dispatch, and any test that hardcodes the same string breaks with it (and fails in a confusing place, not at the rename). Instead map every label the code acts on — button captions, dropdown values — to a stable key in one table, following the existing `glyphs` / `trustGlyphs` / `feedActionLabels` pattern, and branch on `table.key`. Build the widget's button list from that same table so the caption and the dispatch key can't drift apart. These label tables are plain tables (like `glyphs`), not `Enum`s — the `Enum` rule is for value domains, not presentation lookups.

Expose any such map a test needs the same way as other internals — an automation script's `registerMacros` test exports, or a module's `withTestExports` — and have the test key off it too (`buttons.discover`, not `"Fetch/Discover"`). A caption change is then a one-line edit in the map, with the button list, the dispatch, and the tests all following automatically. Purely decorative maps a test never inspects (a glyph legend, a provenance description) can stay local to the function that renders them.

## luarocks

Never run `luarocks install` (or any state-modifying luarocks command) without explicit user permission. If a rock is needed, tell the user which one and suggest:

```bash
luarocks --lua-version=5.1 install <rock>
```

Always pass `--lua-version=5.1`. The project uses LuaJIT with `DLUAJIT_ENABLE_LUA52COMPAT`, which is Lua 5.1 ABI-compatible; omitting the flag may resolve the wrong tree.

## Changelog entries

When making significant user-visible changes to a script or module, add changelog entries to `DependencyControl.json` under the current version key for the affected script. The format is an array of plain-English strings, one per notable change. Cover behavior changes, new features, and fixed bugs. Do **not** list internal refactorings, renamed variables, comment edits, or test-only changes. Keep each entry to one or two sentences. Examples of appropriate entries:

```json
"0.7.0": [
  "Automatic update scheduling is now centralized in the DependencyControl Toolbox.",
  "Record: Added getAllRegisteredRecords() to expose the live record registry to tooling."
]
```

## Markdown / prose

Do not insert manual line breaks within a paragraph in Markdown files (README, docs, etc.). Write each paragraph and list item as a single unwrapped line and let the renderer handle wrapping. (Hard wrapping makes later edits produce noisy, ragged diffs.)
