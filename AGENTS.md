# Agent & contributor workflow for DependencyControl

All code style and conventions — formatting, naming, annotations, types, privacy, error handling, testing — live in [STYLE.md](STYLE.md); it is imported below so it is always in view. This file covers the workflow *around* changing the code, plus the prose habits agents fall into that STYLE.md's rules alone don't catch.

Rules are numbered and use the RFC 2119 keywords (**MUST**, **SHOULD**, **MAY**), as in [STYLE.md](STYLE.md), so a review can cite them.

@STYLE.md

## CHK — Compile-check before handoff

- **CHK1.** A `.moon` syntax error makes Aegisub's loader fall through to a misleading "module not found", so a broken edit can look like an unrelated failure. After any `.moon` edit you **MUST** compile every file you changed and fix parse errors before reporting the task done — every changed file in the same turn, not just the last one edited:

  ```bash
  moonc -p path/to/File.moon > /dev/null
  ```

  (The local interpreter is `luajit`; there is no bare `lua`.)

## CL — Changelog entries

- **CL1.** A significant user-visible change to a script or module **MUST** get a changelog entry in `DependencyControl.json`, under the current version key for that script — an array of plain-English strings, one per notable change (behavior changes, new features, fixed bugs). Internal refactors, renamed variables, comment edits, and test-only changes **MUST NOT** be listed. Keep each entry to one or two sentences.

  ```json
  "0.7.0": [
    "Automatic update scheduling is now centralized in the DependencyControl Toolbox.",
    "PackageRecord: Added getAllRegisteredRecords() to expose the live record registry to tooling."
  ]
  ```

## LR — luarocks

- **LR1.** You **MUST NOT** run `luarocks install` (or any state-modifying luarocks command) without explicit user permission. If a rock is needed, name it and suggest the command, always with `--lua-version=5.1` — the project uses LuaJIT built with `-DLUAJIT_ENABLE_LUA52COMPAT`, which is Lua 5.1 ABI-compatible, so omitting the flag may resolve the wrong tree:

  ```bash
  luarocks --lua-version=5.1 install <rock>
  ```

## SP — Spell-checking & dictionaries

The repo is spell-checked with cspell (`cspell.json` plus the word lists in `.cspell/`). The dictionaries are curated and reusable, not a silence-the-warning dumping ground.

<!-- feedloader below is a deliberate counter-example -->
<!-- cspell:ignore feedloader -->

- **SP1.** When cspell flags a word, resolve it in this order; you **MUST NOT** skip ahead to silence it:
  1. A typo — fix it.
  2. A non-conforming identifier or fixture (a lowercase run-on, a cryptic abbreviation, an invented token) — rename it to conform ([STYLE NM1/NM4](STYLE.md#nm--naming)), in test code as much as production.
  3. Genuine terminology — add it to the one right dictionary (SP2).
  4. A genuine format artifact (a UUID template, a git-describe hash, a `%s`-composed message template) — add an inline `-- cspell:ignore <token>` with a one-line reason.

  Silencing a typo, a local name, or a fixture string by adding it to a dictionary is prohibited: it buries the defect and pollutes a shared list. A lowercase run-on is doubly wrong here — cspell splits identifiers on case boundaries, so `feedloader` reads as one unknown word where `feedLoader` splits into two known ones.

- **SP2.** Terminology goes in exactly one list, chosen by the word's nature. `luajit-moonscript.txt` holds Lua/MoonScript language and stdlib terms the bundled `lua` dictionary lacks. `ffi.txt` holds C API symbols bound through the FFI. `project.txt` holds everything for this repo and the DepCtrl ecosystem: own identifiers, rock/tool proper nouns, contributor handles, and prose jargon missing from cspell's base dictionary. Only `project` takes editor "add to dictionary" quick-fixes, and each list's boundary is stated in its `description` in `cspell.json`.

- **SP3.** An external name you cannot rename is terminology even when it looks like an abbreviation: a C symbol (`CURLOPT_PREREQFUNCTION`), a node-type string from a grammar you consume (`"fndef"`). The test is ownership: a contract with code you don't control belongs in a dictionary, while your own identifier or string gets renamed (SP1).

- **SP4.** Vendored third-party code (`**/vendor/**`) is excluded from spell-checking; you **MUST NOT** add its internal identifiers to any list.

## WR — Writing pitfalls (agents especially)

These are prose habits common in AI output but rare in human contributors', so they live here rather than in STYLE.md. They apply to every comment, doc comment, and Markdown file you write.

- **WR1.** Write for a reader who was not part of the change. A comment **MUST** make sense to someone reading the file cold, with no access to the conversation, PR, or commit that produced it. It describes the code as it is — a constraint it relies on, a hazard it guards against — and **MUST NOT** justify the implementation by comparing it to an alternative, another construct, or a previous version. Design rationale goes in the commit message or PR description.
- **WR2.** Delete on sight any comment built on these tells; they narrate a decision instead of documenting behavior: *"unlike …"*, *"rather than / instead of …"*, *"we now / no longer / used to …"*, *"this is better / cleaner because …"*, *"chosen / done this way so that …"*, *"moved here …"*.

  ```moon
  -- GOOD — a constraint the code relies on; stands on its own:
  -- intervals are half-open [min, max), so the greatest satisfying version is max - 1

  -- BAD — narrates a decision; meaningless to a cold reader:
  -- a categorical enum (unlike the ordinal PromptThreshold), so string values rather than numbers
  ```

- **WR3.** Prefer natural language over backticked identifier names in prose. A declared `---@param feedUrl` reads as "the given feed URL", not "`feedUrl`"; drop reflexive "(see `otherMethod`)" pointers. Reserve backticks for when the exact name is what the caller acts on — a config key they set (`extraFeeds`), an enum value the result equals, a field they inspect (`stats.truncated`) — not as an echo of a declared parameter. LuaCATS has no inline link syntax, so a backticked name is just literal clutter.
- **WR4.** Clustered punctuation is a smell — in `--` comments, doc comments, and Markdown alike. No single mark is banned, but when parentheses, semicolons, colons, and em dashes pile up in one sentence, reorganize it. Watch for a semicolon nested inside a parenthetical, stacked parentheticals, an em-dash aside in a clause that already carries parens or a semicolon, a closing paren shoved against a semicolon, or a `label:` headline hung off a colon. The fix is one aside per sentence.
- **WR5.** Keep annotation prose short. A doc comment **SHOULD** default to one line, gaining a second only for a genuinely separate contract (a precondition, a side effect), never to pad.
- **WR6.** Don't manufacture detail to fill space. The summary and the `---@return` **MUST NOT** be padded with invented specifics to force a difference between them; a concise `@return` shape label that echoes the summary is fine.
- **WR7.** A comment **MUST** stay inside the method it documents — state this call's contract, not what another method does ("(run acquires the lock first)").
