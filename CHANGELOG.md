# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Initial release: Elixir port of [lovely-mermaid](https://github.com/xl0/lovely-mermaid).

### Added

- **`LovelyMermaid.render/1`** — render Mermaid diagrams as Unicode box-drawing
  art for terminals. Returns `%LovelyMermaid.Art{}` (`plain`, `styled` span
  runs, `width`, `class_defs`, `warnings`) or `nil`.
- **`LovelyMermaid.diagram_kind/1`** — detect the diagram kind from the header
  (`:flowchart`, `:state`, `:class`, `:er`, `:sequence`, `:pie`, `:mindmap`,
  `:timeline`, `:gitgraph`, or `nil`).
- **Diagram kinds** — `flowchart`/`graph` (incl. `subgraph`), `stateDiagram`,
  `classDiagram`, `erDiagram`, `sequenceDiagram`, `pie`, `mindmap`,
  `timeline`, `gitGraph`.
- **Flowchart v2 node syntax** `id@{shape: …, label: …}` — 27 shape names
  collapsed to round/diamond/rect silhouettes; diamond nodes render as
  double-line boxes with mixed `╤`/`╧`/`╟`/`╢` edge tees.
- **`state X { … }` composites** — nested frames; `--` splits a composite
  into unlabelled sibling region frames.
- **Sequence `Note` anchors** auto-register the participants they name.
- **`classDef` styles, `:::name` / `class A,B name` author classes, `click`/
  `link` hrefs** — carried on styled spans, styled by `Ansi.to_ansi/2`
  (incl. OSC 8 hyperlinks).
- **YAML frontmatter `title:`** — drawn centred above the art.
- **`LovelyMermaid.SourceBox.source_box/2`** — framed-source fallback when a
  diagram won't render.
- **`LovelyMermaid.Ansi.to_ansi/2`** — ANSI-coloured output from `art.styled`.
- **Warning/retry strategy for streaming sources** — flowcharts report
  dropped statements in `warnings`; other grammars fail the whole diagram,
  with one retry dropping the final line.

[Unreleased]: https://github.com/gilbertwong96/lovely_mermaid
