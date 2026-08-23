# Changelog

## Unreleased

Initial release: Elixir port of [lovely-mermaid](https://github.com/xl0/lovely-mermaid) (formerly grok-mermaid).

- `LovelyMermaid.render/1` — render Mermaid diagrams as Unicode box-drawing art
- Diagram kinds: `flowchart`/`graph` (incl. `subgraph`), `stateDiagram`,
  `classDiagram`, `erDiagram`, `sequenceDiagram`, `pie`, `mindmap`,
  `timeline`, `gitGraph`
- Flowchart v2 node syntax `id@{shape: …, label: …}` (27 shape names →
  round/diamond/rect silhouettes); diamond nodes render as double-line boxes
  with mixed `╤`/`╧`/`╟`/`╢` edge tees
- `state X { … }` composites as nested frames; `--` splits a composite into
  unlabelled sibling region frames
- Sequence `Note` anchors auto-register the participants they name
- `classDef` styles, `:::name` / `class A,B name` author classes, `click`/
  `link` hrefs — carried on styled spans, styled by `Ansi.to_ansi/2` (incl.
  OSC 8 hyperlinks)
- YAML frontmatter `title:` centred above the art
- Warning/retry strategy for streaming sources
- `LovelyMermaid.SourceBox.source_box/2` — framed-source fallback
- `LovelyMermaid.Ansi.to_ansi/2` — ANSI-coloured output
