# Changelog

## Unreleased

Initial release: Elixir port of [grok-mermaid](https://github.com/xl0/grok-mermaid).

- `GrokMermaid.render/1` — render Mermaid diagrams as Unicode box-drawing art
- Diagram kinds: `flowchart`/`graph` (incl. `subgraph`), `stateDiagram`,
  `classDiagram`, `erDiagram`, `sequenceDiagram`
- Grapheme-aware width table (UAX #11), semantic style spans, ANSI theme
- Warning/retry strategy for streaming sources
- `GrokMermaid.SourceBox.source_box/2` — framed-source fallback
- `GrokMermaid.Ansi.to_ansi/2` — ANSI-coloured output
