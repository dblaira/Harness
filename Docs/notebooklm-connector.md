# NotebookLM Connector

Harness treats NotebookLM as synthesized research context, not accepted graph authority.

## Default Import Folders

Add exported notebooks, copied study guides, audio transcripts, briefing docs, or source-pack files to:

- `~/Documents/Harness/NotebookLM`
- `~/Library/Mobile Documents/com~apple~CloudDocs/Harness/NotebookLM`

Additional folders can be configured with `HARNESS_NOTEBOOKLM_ROOTS`, separated by `:` or newlines.

The easiest path in the app is:

1. Download the NotebookLM-created file.
2. In Harness, press `+`.
3. Choose `NotebookLM` -> `Import from Downloads...`.
4. Select the downloaded file.

Harness copies the file into the NotebookLM import folder and inserts a source reference into the chat box automatically.

PowerPoint, PDF, Word, Markdown, text, HTML, and RTF files are accepted. For binary files such as PowerPoint, Harness also creates a small `.harness.md` index note beside the imported file so the import is visible to source search.

## Trust Labels

Unlabeled NotebookLM files are treated like external web synthesis. They can support an answer, but they cannot become accepted authority by themselves.

To mark a notebook export as your own data or direct thought, add one of these labels near the top of the file:

```yaml
source-class: personal-data
```

```yaml
source-class: direct-thought
```

The labels change the source reason shown in memory hits, but the material still remains supporting memory until it is promoted through candidate review and accepted graph validation.
