# DependencyControl code style & conventions

The house style for DependencyControl, for human contributors and AI agents alike. It records how the code is written and structured so new code reads like the code already here. Examples are MoonScript, the language the module sources are written in.

Rules are numbered (`ER1`, `NM3`, …) so a review can cite them. The keywords **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are used in the RFC 2119 sense: **MUST** is a hard requirement, **SHOULD** is a strong default with rare and justified exceptions, **MAY** is a genuine option. Where a rule carries a "why", follow the rule — the rationale is there to help you apply it to cases it doesn't name, not to reopen it.

Scope: this file is about the code. Contributor and agent *workflow* (verifying changes, changelog entries, dependency installs) and the *writing pitfalls* agents fall into live in [AGENTS.md](AGENTS.md), which imports this file so both are always in view.

## FMT — Language & formatting

- **FMT1.** Indentation **MUST** be two spaces per level, spaces only (no tabs), with LF line endings, a trailing newline, and no trailing whitespace. An `.editorconfig` encodes this.
- **FMT2.** Doc comments **MUST NOT** put a space after the marker: `---Text`, not `--- Text`. Intentional structure *inside* a doc comment is exempt — bulleted lists (`--- * item`), indented code examples (`---    code`), and aligned continuations keep their spacing.
- **FMT3.** Code **MUST NOT** be column-aligned. Do not pad assignments, table values, or trailing comments into columns; use a single space. Alignment rots the moment a longer entry is added and turns a one-line change into a whole-block diff, and nothing in the toolchain maintains it.
- **FMT4.** For string composition, `"template"\format args` against a `msgs` template **SHOULD** be the default; `"#{...}"` interpolation is for ad-hoc composition. `string.format` and `..` concatenation are rare and usually avoidable.
- **FMT5.** In Markdown files (README, docs, this file), each paragraph and list item **MUST** be a single unwrapped line — no manual line breaks within a paragraph. Hard wrapping produces noisy, ragged diffs on later edits.

## MS — MoonScript idioms

- **MS1.** Prefer the language's idioms, as the existing sources do: `unless` over `if not`; postfix conditionals and loop modifiers; list/table comprehensions; `x or= value` for lazy init; `@field` capture in constructor signatures; `tbl[#tbl + 1] = v` over `table.insert`; `with` blocks for record mutation; `!` for nullary calls.
- **MS2.** `or=` is a statement, not an expression: a method whose whole body is `@field or= value` returns `nil`. You **MUST** add an explicit `return @field` after a lazy-init `or=` when the caller expects a value.
- **MS3.** `@@field arg` / `@field arg` compile to *colon* calls (`self.__class:field(arg)` / `self:field(arg)`), passing an implicit first argument. When the field holds a constructor or plain function you want to call plainly, you **MUST** write `@@.field arg` / `@.field arg` (or bind it to a local first).
- **MS4.** A constructor's return value is discarded — `Cls(...)` always yields the instance, so a `return nil, err` inside `new` is dead code. Validation a caller can trip **MUST** happen before or around construction (in the factory), not inside `new`.

## MOD — Files & modules

- **MOD1.** A `.moon` file that defines and returns a single class **MUST** be named after that class in PascalCase (`FeedTrust.moon`). Any other file — a helper returning a function or table, an FFI shim — **MUST** be kebab-case (`resolve-host.moon`, `config-schema.moon`). Test files mirror the name of what they test.
- **MOD2.** Requires go at the top: stdlib / `ffi` / `lfs` / `json` first, then `l0.DependencyControl.*`. Larger blocks **SHOULD** be alphabetized with the `=` column aligned; small files needn't.
- **MOD3.** Inheritance **SHOULD** be rare and thin; composition and constructor injection are the norm.
- **MOD4.** A module **MUST** end with an explicit `return` of the value it exports — the class it defines, the table it returns, or the `withTestExports`/`Accessors.install` result — never an implicit class-statement or final-expression return. Explicit is the one form that stays valid when a post-class attachment is added later, so the file's ending never has to change.

## CT — Class or plain table

- **CT1.** Reach for a `class` only when its instances will carry state or behavior — when the type is genuinely constructed, now or foreseeably. A module that is only a namespace of stateless functions (optionally with `Enum`s or constants) **MUST** be a plain table the file returns, not a class. A `class` advertises a constructor to every caller and to tooling; using one for a never-constructed namespace hands users the wrong mental model.
- **CT2.** When instances are only a maybe-someday, **SHOULD** ship the table and upgrade later. The upgrade is caller-compatible in one direction: a function called `Mod.fn(args)` becomes a static `@fn = (args) ->` with the same signature, and gaining a class merely *adds* a constructor. Retiring a class callers already construct is the breaking direction. The upgrade renames the file and require path (`hash.moon` → `Hash.moon`), but those are internal, not a published surface.
- **CT3.** A table module **MUST** still carry a `---@class Name` on the value it returns, purely as a type name; with no constructor behind it, nothing suggests the type is constructable. (Some existing all-static classes predate this — treat them as legacy to migrate, not precedent.)
- **CT4.** A module's public re-export **MUST** use the PascalCase name the module would carry as a class, even while it is a table (`DependencyControl.Hash`, not `.hash`). The re-export is a published surface; pinning it now means a later table→class upgrade never renames the accessor.
- **CT5.** Call form follows the binding, not taste — `=>`/colon means "receives `self`", `->`/dot means "plain function", so a member's calling convention is fixed by what it needs:
  - Instance methods are fat-arrow, colon-called (`obj\method`).
  - A class static that touches class state (`@`/`@@`) is fat-arrow, colon-called (`Class\name`); a plain static helper is thin-arrow, dot-called (`Class.name`), as are all functions on a table module.
  - You **MUST NOT** push a table's functions into the colon form to chase uniformity — it misrepresents them as instance-bound and breaks the upgrade path (CT2). Preferring table modules for stateless namespaces keeps most "static utilities" dot-called, leaving colon for genuine class-state methods.
- **CT6.** Bind a table module to a `camelCase` local at each import (`fileOps = require "l0.DependencyControl.file-ops"`); the module's own returned table and its public re-export stay on the PascalCase type name (CT4). The lowercase local marks a namespace rather than a constructor, and is the one binding a later table→class upgrade would rename. Keep a PascalCase local only where the camelCase form would shadow a value — `Hash`, since `hash` routinely names a digest.

## NM — Naming

<!-- the run-on spellings below are deliberate counter-examples in the NM and ID rules -->
<!-- cspell:ignore feedloader dlen nofiles ziparchiver -->

- **NM1.** Casing **MUST** be: `camelCase` for methods, fields, and locals; `PascalCase` for classes and `Enum` members; `UPPER_SNAKE` for module-level constants. `snake_case` appears only at the Aegisub API and C FFI boundaries, never in project-native code. A compound camelCase name **MUST** show its word boundaries rather than run the words together — `feedLoader`, not `feedloader`. Each segment **SHOULD** be a whole word, not a truncation (`digestLen` over `dlen`), though short conventional abbreviations like `id`, `ns`, `len`, and `msg` are fine. A name that mirrors an external source — a C symbol, a grammar node type — keeps that source's spelling.
- **NM2.** Name a member by its role, not a part-of-speech rule. Commands (do work, have effects) take a verb (`getEffectiveSource`, `persistSource`); predicates use `is`/`has`/`should` (`isBlocked`, `hasTeardown`); value producers may lead with a preposition or copula (`toString`, `fromJSON`, `withoutInstall`).
- **NM3.** A member that acts **MUST NOT** have a bare-noun name (`failures`, `scriptTypes` read as fields). Litmus: read the name as a field access; if it does work but looks like stored data, it's wrong. Two fixes, and the choice matters: a *command* takes a verb (`getFailures`); a derived *value* with no side effects **SHOULD** instead become an actual read-only [computed property](#cp--computed-properties) so the noun becomes honest (`filter.scriptTypes`, `timer.elapsed`). A sampling or effectful call stays a verb-named method.
- **NM4.** These naming rules apply to test code and to identifier-like string literals — fixture names, temp-path segments, stand-in namespaces (`"l0.noFiles"`, not `"l0.nofiles"`) — not only to production identifiers. A throwaway test string is still read by people and tools; being a placeholder is not license to skip the conventions.

## DOC — Types & annotations

- **DOC1.** All doc comments **MUST** use [LuaCATS](https://github.com/LuaLS/lua-language-server/wiki/Annotations), never legacy *ldoc*:

  | ldoc (never)               | LuaCATS (always)          |
  |----------------------------|---------------------------|
  | `-- @tparam string x desc` | `---@param x string desc` |
  | `-- @treturn boolean`      | `---@return boolean`      |
  | `-- @classmod Foo`         | `---@class Foo`           |
  | `-- @param[opt] x`         | `---@param x? type`       |

- **DOC2.** Every parameter and return **MUST** be documented; optional params use `---@param name? type`. A `---@class` sits immediately before the class, or on the table a module returns.
- **DOC3.** Plain data shapes **SHOULD** get standalone `---@class`/`---@alias` blocks even with no runtime class (`RecordArgs`, `SemverInterval`, `FeedFileData`).
- **DOC4.** A doc comment states the *contract* — what the caller passes, what comes back, any side effect — at the highest altitude that still informs. It **MUST NOT** restate the body: describe the outcome a caller relies on, not the branches that produce it.
- **DOC5.** Every `---@return` **MUST** carry a description, not just a type. State the concrete shape and the non-obvious edge conditions the summary omits: the nil case, ordering, emptiness.

## EN — Enums

- **EN1.** Enumerated value domains **MUST** use the `Enum` class (`Enum "Name", {Key: value}`), not a plain table — it gives immutability and value/key reverse lookup.
- **EN2.** Because `Enum` instances are built at runtime (so `---@enum` can't apply), each **MUST** be documented by an `---@alias` placed directly above it, one `---| <value> # <Key>: <description>` line per member. Keep the descriptions in the alias (single source of truth), leave the runtime table bare, and reference the alias in annotations:

  ```moon
  ---@alias UpdaterTrustBand
  ---| 1 # DeclaredDirect: the declared/own feed, trusted, offering the module by name
  ---| 2 # TrustedDirect: another trusted feed, offering the module by name
  TrustBand = Enum "UpdaterTrustBand", {
    DeclaredDirect: 1
    TrustedDirect: 2
  }

  ---@param band UpdaterTrustBand
  ```

- **EN3.** Presentation maps (dialog label/glyph tables and the like) are not value domains and **MUST** stay plain tables, not `Enum`s (see [DLG](#dlg--dialog-labels--dispatch)).

## CP — Computed properties

- **CP1.** A field whose read or write must run code — a derived value, or a stored value needing conversion — is a computed property and **MUST** be declared with the `Accessors` module, not a hand-written `__index`/`__newindex`. Mark it in the class body, then call `Accessors.install` once after the body (and, for a subclass, after the parent's `install`):

  ```moon
  Accessors = require "l0.DependencyControl.Accessors"

  class PackageRecord
    version: Accessors.property
      get: => @semanticVersion\toPacked!
      set: (value) => @semanticVersion = SemanticVersion.fromPacked SemanticVersion\toPacked value
  Accessors.install PackageRecord
  ```

- **CP2.** Omit `set` for a read-only property (a write then raises). A readable property appears in `pairs(instance)` and runs its getter, so you **MUST** initialize the backing field before the property can be read, and **MUST NOT** `pairs` a class's `__base` (its getters have no instance).
- **CP3.** Annotate a property's type with a `---@field` on the `---@class`, not through the `property{…}` call — the accessor is invisible plumbing. LuaCATS has no read-only marker, so note read-only in the `@field` description and let `install` enforce it.
- **CP4.** Not every derived read is a property: a property's getter **MUST NOT** reach off the machine or sample changing state. It may read in-memory values, the local filesystem, or a bounded read-only local subprocess (a `git` query), and **SHOULD** memoize a lazy result into a backing field. A read that resolves a hostname, fetches over the network, or returns a value that differs between calls stays a `get*` method instead — the `!` at that call site deliberately signals work that can hang, fail, or change, and hiding it behind a field access is what to avoid. Local, so properties: `timer.elapsed`, `record.version`. Off-machine or sampling, so methods: `host\resolvesToPrivate!` (DNS), `feedTrust\getTrustedFeeds!` (loads a feed), `lock\getActiveHolder!` (samples the holder).

  ```moon
  ---@class PackageRecord
  ---@field version integer Packed-integer view over `semanticVersion`; assignable from a string, packed int, or instance. Read-only.
  ```

## CM — Comments

- **CM1.** Use an inline `--` comment only when the *why* is non-obvious: a hidden constraint, a subtle invariant, a language gotcha. It **MUST NOT** describe *what* the code does — well-named identifiers already do that.
- **CM2.** A comment **MAY** state a non-obvious constraint or design choice when it directly affects how callers use the API. "Automation scripts have their tests registered when they call `registerMacros`" is a behavioral contract and belongs; "this replaces the old per-environment scheduling" is history and does not.
- **CM3.** Design rationale, comparisons to a previous version, and the story of how the code got here **MUST NOT** live in a comment; they go in the commit message or PR description. (Agents are especially prone to this — see [AGENTS.md `WR`](AGENTS.md#wr--writing-pitfalls-agents-especially).)
- **CM4.** Substantial "why" blocks above non-obvious code are welcome (the long-path detection in FileOps, the SSRF notes in Downloader). Region banners (`-- Shared Functions`) **SHOULD** be used only in the largest files.

## PV — Privacy & the public API

- **PV1.** Anything not meant to be called from outside its own class **MUST** be marked `---@private` and prefixed `__` (the type generator also treats a leading `__` as private). The language server then flags external `obj.__method()` access while allowing `@method`/`@@method` inside.
- **PV2.** A member is public if it's a safe, stable building block a third party building on the framework could reasonably use — whether or not anything here calls it yet. Mark `---@private` only genuine implementation details; an existing external caller proves a method public, its absence does not prove it private. You **MUST NOT** narrow a member that was public in a prior release — that is a silent breaking change. Tests are exempt (they drive internals via the stub-self pattern).
- **PV3.** A single leading `_` is a deliberate middle tier, not an under-marked private: the internal contract shared within a subsystem (a mixin and its subclasses, a manager and its injectable collaborators) but not general public API — `EventEmitter._emit`, the `Download`↔runner callbacks. Use `_` for those and `__` for what only the defining class touches, and state the distinction in a header comment where a file leans on it.
- **PV4.** A mock-worthy dependency **MUST** live in a `---@private` class field (`@@__dep`/`@__dep`) that a test can swap, not a module-local upvalue nothing outside the file can replace.
- **PV5.** A module-private sentinel or marker key **MUST** be a namespaced string built from the shared prefix (`"#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}SomeName"`), not a bare `{}` or plain name, so it stays collision-free while remaining inspectable and serializable.

## TX — Exposing internals for tests

- **TX1.** To *read* a private value from a test, you **MUST NOT** add a test-only field to the public API; use the `UnitTestSuite` test-export helpers, which stash the exports on the module's metatable (off the normal indexing surface):

  ```moon
  -- end of MyModule.moon
  UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
  return UnitTestSuite\withTestExports MyModule, {:somePrivate}

  -- in the test file
  {:somePrivate} = UnitTestSuite\getTestExports require "l0.DependencyControl.MyModule"
  ```

- **TX2.** A module that sits in `UnitTestSuite`'s own dependency chain (a low-level module like `hash`) **MUST NOT** require `UnitTestSuite` for this (it would create a load cycle); it exposes its test-only reference through a `---@private` field instead.

## ER — Errors & messages

- **ER1.** Expected failures **MUST** return `nil, errMsg` (or a status code). `error()`/`assert` are reserved for programmer error and constructor-contract violations.
- **ER2.** A tri-state return **MUST** distinguish absent from failed: `nil, err` is a hard error, `false` is legitimately-not-there. The `---@return` **MUST** document both cases.
- **ER3.** Every user-facing string **MUST** live in a `msgs` table of `%s` templates and **MUST NOT** be an inline literal. New `msgs` tables **SHOULD** be module-locals, keyed by method name (private methods included: `msgs.__refreshFiles.noLocalPath`).
- **ER4.** Error strings **SHOULD** end in a period; progress messages **SHOULD** end in `…`; messages **MUST NOT** use an `"Error: "` prefix. A lowercase fragment **MAY** appear only as a composable sub-message.

## LOG — Logging

- **LOG1.** Loggers use numeric levels (fatal 0 → trace 5) with method sugar; a call passes the template plus args and the logger formats: `@logger\log msgs.run.starting, a, b`.
- **LOG2.** `logger\error` throws by design (log-and-abort); `logger\assert cond, msg, …` is the standard guard.
- **LOG3.** A logger **SHOULD** be injected with a default: a module-local `defaultLogger` plus a constructor parameter (`@logger = defaultLogger`), so tests can pass their own.
- **LOG4.** A subsystem logger's `fileBaseName` **MUST** be `"#{Constants.DEPCTRL_SHORT_NAME}.<Class>"` — the short `DepCtrl.` prefix, single-sourced. It's a display label that sits beside the hosting script's namespace in filenames and line prefixes, where the short form reads best.

## ID — Derived identity strings

- **ID1.** Compose a string that encodes the module's own identity from the owning constant or class, never from a hardcoded literal that restates it. A temp-file name, working-path segment, logger label, or namespaced marker **SHOULD** derive its identifying prefix — `"#{constants.DEPCTRL_SHORT_NAME}-#{@@__name}-#{token}.json"`, not `"depctrl-ziparchiver-#{token}.json"`. The literal drifts when the class is renamed; the derived form cannot. ([LOG4](#log--logging) applies this to `fileBaseName`.)

## CFG — Config access

- **CFG1.** Config **MUST** flow through `ConfigView`: read/write `@config.c.<section>.<key>`, mutate, then `@config\save!`.
- **CFG2.** A config default **SHOULD** live on its sole owning class (`FileCache.defaultMaxAge`, read as `… or @@defaultMaxAge`); the central `config-schema.moon` tree is only for settings shared across subsystems.
- **CFG3.** A key prefixed `_` is excluded from serialization; use that prefix for transient state stamped onto config-backed tables.

## DLG — Dialog labels & dispatch

- **DLG1.** Code **MUST NOT** branch on a raw dialog label. Map every acted-on label (button captions, dropdown values) to a stable key in one table, branch on `table.key`, and build the widget's button list from that same table so caption and dispatch can't drift.
- **DLG2.** These label tables are presentation maps and **MUST** stay plain tables, not `Enum`s.
- **DLG3.** Expose a label map a test needs like other internals (`withTestExports` or `registerMacros` exports) and key the test off it (`buttons.discover`, not `"Fetch/Discover"`). A purely decorative map a test never inspects **MAY** stay local to its render function.

## TS — Testing

- **TS1.** `test.moon` is a single `UnitTestSuite` importing each class's test file via `controls\requireTest "Name"`. A test file **MUST** open with a header comment (what it tests, how it's called) and return a table of `testName: (ut) ->` entries, with optional `_description`/`_setup`/`_teardown`/`_order`/`_condition`.
- **TS2.** Test names **MUST** follow `method_behavior` (`put_expiryFixedAtWriteTime`, `scheduleUpdate_withinIntervalSkips`).
- **TS3.** Drive an instance method without constructing the object via the stub-self pattern: `setmetatable {…fields…}, __index: Class.__base`, then `Class.method(fakeSelf, …)`.
- **TS4.** Mock via `ut\stub`/`ut\spy`/`ut\stubModule`, and **SHOULD** exploit the injectable seams (clock, resolver, feed loader, transfer runner) rather than monkey-patching module internals.
