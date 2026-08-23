# Changelog

## Unreleased

Initial release: Elixir port of [grok-mermaid](https://github.com/xl0/grok-mermaid).

- `GrokMermaid.render/1` — render Mermaid diagrams as Unicode box-drawing art
- Diagram kinds: `flowchart`/`graph` (incl. `subgraph`), `stateDiagram`,
  `classDiagram`, `erDiagram`, `sequenceDiagram`, `pie`, `mindmap`,
  `timeline`, `gitGraph`
- `classDef` styles, `:::name` / `class A,B name` author classes, `click`/
  `link` hrefs — carried on styled spans, styled by `Ansi.to_ansi/2` (incl.
  OSC 8 hyperlinks)
- YAML frontmatter `title:` centred above the art
- Warning/retry strategy for streaming sources
- `GrokMermaid.SourceBox.source_box/2` — framed-source fallback
- `GrokMermaid.Ansi.to_ansi/2` — ANSI-coloured output
