## Zig Documentation Agent Policy

### Purpose

Maintain unusually thorough, accurate, and useful documentation for the repository's first-party Zig source files.

Documentation work must improve understanding without changing program behavior.

### Scope

Documentation tasks may modify only:

* First-party `*.zig` files
* `docs/zig-docs-manifest.json`
* Documentation indexes or generated documentation configuration explicitly named in the task

Do not modify:

* Vendored dependencies
* Generated source files
* Zig cache directories
* Dependency caches
* Git submodules
* Files under directories named `vendor`, `third_party`, `deps`, `.zig-cache`, or `zig-out`, unless the task explicitly includes them

Before editing, identify which Zig files are first-party, generated, vendored, examples, tests, benchmarks, tools, or production source.

### Absolute Restrictions

Documentation-only tasks must not change:

* Runtime behavior
* Algorithms
* Control flow
* Function signatures
* Types
* Visibility such as `pub`
* Error sets
* Memory ownership
* Allocation behavior
* Build configuration
* Imports
* Tests, except for adding a documentation example specifically authorized by the task

Do not refactor code while documenting it.

Do not rename declarations, parameters, fields, files, or modules.

Do not “clean up” nearby code.

Do not fix discovered bugs during a documentation task. Report them separately.

If a documentation change appears to require a code change, stop and report the conflict instead.

### Documentation Standards

Every included Zig source file should have an accurate `//!` module-level description when the file represents a coherent module.

Module documentation should explain, where applicable:

* The module's responsibility
* Its place in the surrounding architecture
* Important entry points
* Major data flows
* Ownership and lifetime expectations
* Allocation behavior
* Error-handling strategy
* Thread-safety or concurrency expectations
* Compile-time behavior
* Platform or target assumptions
* Important invariants
* Major side effects
* Relevant security or correctness constraints
* A small usage example when a stable public entry point exists

Every public declaration should have useful `///` documentation unless it is genuinely self-explanatory and additional text would add no information.

Public function documentation should cover, where applicable:

* What the function accomplishes
* Preconditions
* Parameter semantics
* Return-value semantics
* Possible errors and their meaning
* Ownership of inputs and outputs
* Borrowing and lifetime requirements
* Whether memory is allocated
* Whether the caller must free anything
* Mutation and side effects
* Thread-safety
* Reentrancy
* Compile-time versus runtime behavior
* Complexity or performance characteristics, but only when supported by the implementation
* Edge cases
* Failure behavior
* A concise example for non-obvious APIs

Type documentation should cover, where applicable:

* What the type represents
* Valid and invalid states
* Field relationships
* Invariants
* Ownership responsibilities
* Initialization and deinitialization
* Whether values may be copied safely
* Thread-safety
* Serialization or ABI considerations
* Important lifecycle transitions

Field documentation should explain semantics, units, ranges, sentinel values, ownership, and invariants when these are not obvious.

Private declarations should be documented when they implement a non-obvious algorithm, maintain an important invariant, encode a protocol rule, or have surprising ownership or performance behavior.

### Accuracy Rules

Documentation must be derived from:

1. The implementation
2. Existing tests
3. Call sites
4. Build configuration
5. Existing repository documentation

Never invent behavior from a declaration name alone.

Never claim:

* Thread-safety without evidence
* Constant-time behavior without evidence
* Allocation-free behavior without evidence
* Stable ABI or API guarantees without evidence
* Particular complexity without inspecting the implementation
* Ownership transfer without inspecting call sites and cleanup behavior
* Platform support not demonstrated by the build configuration
* Error behavior not represented by the implementation

When behavior cannot be established confidently:

* Do not guess
* Do not insert vague assurances
* Add the uncertainty to the task report
* Leave the existing documentation unchanged if a replacement would be speculative

Use the words `assume` and `assert` consistently with Zig's documented convention for unchecked and safety-checked invariants.

Avoid documentation that merely repeats the declaration's name or type signature.

Duplicating essential behavioral information across related public declarations is acceptable when it improves editor and generated-documentation usability.

### Examples

Prefer examples that compile against the current repository.

Do not add examples that rely on imaginary APIs.

When an example can reasonably be expressed as a Zig test, prefer a small testable example, but only when the task explicitly permits adding tests.

Examples must show required cleanup such as `defer`, allocator ownership, or deinitialization.

Examples must not hide important error handling.

### Change Tracking

Maintain `docs/zig-docs-manifest.json`.

For each included Zig file, record:

* Repository-relative path
* Content hash
* Last documented commit
* Documentation status
* Last documentation review date
* Any unresolved documentation questions

The content hash must represent the source file's meaningful contents. Do not rely only on filesystem timestamps.

A recurring documentation task should process only:

* New Zig files
* Modified Zig files
* Renamed Zig files
* Files whose manifest entry is missing or invalid

Deleted files should be removed from the manifest.

A file is considered changed when its current content hash differs from the manifest.

Do not update a manifest hash unless that file was actually reviewed during the task.

### Batch Size

Initial documentation work must be divided into small, coherent batches.

A batch should normally contain no more than:

* 5 substantial Zig files, or
* 10 small Zig files

Group files by module or subsystem rather than arbitrary alphabetical slices.

Each batch must result in an independently reviewable pull request.

Do not attempt a repository-wide rewrite in one pull request.

### Validation

Use the Zig version pinned or documented by the repository.

After documentation edits:

1. Run the repository's canonical formatting check.
2. Run the repository's canonical build command.
3. Run the repository's canonical test command.
4. Generate Zig documentation when the repository provides a supported command for doing so.
5. Inspect the diff for accidental non-comment changes.

If no canonical commands are documented, determine them from `build.zig`, `build.zig.zon`, CI configuration, and existing scripts.

Do not silently substitute commands intended for a different Zig version.

A documentation task is incomplete when formatting, compilation, or tests fail because of its changes.

Pre-existing failures must be clearly distinguished from failures introduced by the documentation changes.

### Required Task Report

Every documentation task must report:

* Zig files examined
* Zig files changed
* Zig files intentionally skipped
* Why each skipped file was excluded
* Public declarations documented
* Important private declarations documented
* Unresolved ambiguities
* Potential bugs discovered but not changed
* Validation commands executed
* Validation results
* Manifest entries added, updated, renamed, or removed
* Confirmation that no behavioral code was changed
