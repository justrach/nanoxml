The agent release: nanoxml is now a CLI tool agents can drive end to end — JSON output, write verbs, stdin piping, strict exit codes, and a one-liner installer. See [AGENTS.md](https://github.com/justrach/nanoxml/blob/main/AGENTS.md) for the full contract.

```bash
curl -fsSL https://raw.githubusercontent.com/justrach/nanoxml/main/install.sh | sh
```

## New since v0.0.1

- `--json` on `info` / `parts` / `sheets` / `validate`
- `set-cell <file> <sheet#> <A1> <value>` — typed cell edits (auto number/string detection, `--string`/`--number` overrides), in place or `--out`
- `set-props` — title/creator/subject/description write-back
- `set-part` / `rm-part` — surgical part editing, stdin supported (`-`)
- `from-csv` — CSV → real xlsx (byte-identical CSV round-trip; numbers stay numbers, quoting and gaps preserved)
- `from-text` — lines → docx paragraphs
- `install.sh` one-liner installer
- flags accepted anywhere in the argv; status messages on stderr, data on stdout

Everything from v0.0.1 still holds: feature parity with dotnet/Open-XML-SDK refereed by Microsoft's own `OpenXmlValidator` (0 errors on all nanoxml output), 179 ms vs the SDK's 833 ms on the 200k-row benchmark, 500+ tests.

macOS binaries are signed (Developer ID). `checksums.sha256` covers all assets.
