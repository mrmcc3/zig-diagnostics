# zig-diagnostics

A language server for Zig that only reports diagnostics for now.

- AST errors when the document opens/changes.
- ZIR errors when the document saves.

### Motivation

[Helix] has solid support for zig out of the box

- `hx --health` reports Syntax Highlighting, Treesitter Textobjects, Auto Indent
- `zig fmt` is configured by default for formatting.

There's support for [ZLS][zls] however I'd rather not rely on a full-featured
language server until the language itself stabilizes or official tooling is
released.

Helix requires a language server to report diagnostic information. Fast feedback
within the editor is essential for quickly fixing syntax/semantic errors.
Without it you have to blindly wonder why formating isn't working.

That's the goal of this project - a minimal langauge server that reports
diagnostics.

### Design

- didOpen/didChange run AST parser in the LS process
- didSave open a child process to `zig fmt --stdin --ast-check --check` and
  parse any error information from stderr

[helix]: https://helix-editor.com/
[zls]: https://github.com/zigtools/zls
