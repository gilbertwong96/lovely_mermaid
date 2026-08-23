# LovelyMermaid: porting plan

Elixir port of the terminal Mermaid renderer. Two reference implementations:

- **Rust original**: `xai-org/grok-build` → `crates/codegen/xai-grok-markdown/src/mermaid.rs`
  (~4k lines, `graph`/`flowchart`, `sequenceDiagram`, `stateDiagram`)
- **TypeScript port**: `xl0/lovely-mermaid` (npm, zero-dep) — the primary
  reference. Adds `classDiagram`, `erDiagram`, `subgraph`, semantic class
  spans, a grapheme-aware width table, and a warning/retry strategy.

## Module map (TS → Elixir)

| TS source | Elixir module | Notes |
|---|---|---|
| `width.ts` + `width-data.ts` | `LovelyMermaid.Width` | UAX #11 table is generated from `width-data.ts`; grapheme clustering via `String.graphemes/1` (UAX #29, same as `Intl.Segmenter`) |
| `canvas.ts` | `LovelyMermaid.Canvas` | Direction-bit accumulation (`U/D/L/R`), line styles, `occupied`, `finalizeMask`, `blit`. The core of correct crossings |
| `graph.ts` | `LovelyMermaid.Graph` | Shared model + caps (`MAX_NODES=128`, `MAX_EDGES=512`, …) |
| `labels.ts` | `LovelyMermaid.Labels` | ANSI stripping, `asciiUpper`, label helpers |
| `parse.ts` | `LovelyMermaid.Parse` | `flowchart`/`state`/`class`/`er`/`sequence` grammars |
| `diagrams/pie.ts` | `LovelyMermaid.Pie` | Bar-list proportions |
| `diagrams/mindmap.ts` | `LovelyMermaid.Mindmap` | Indentation tree |
| `diagrams/timeline.ts` | `LovelyMermaid.Timeline` | Periods and events |
| `diagrams/gitgraph.ts` | `LovelyMermaid.GitGraph` | Commit lanes |
| `layout.ts` | `LovelyMermaid.Layout` | Flowchart (incl. `subgraph`), class, ER layout |
| `layout-seq.ts` | `LovelyMermaid.LayoutSeq` | Sequence diagram layout |
| `ansi.ts` | `LovelyMermaid.Ansi` | `Cls` → ANSI theme mapping |
| `source-box.ts` | `LovelyMermaid.SourceBox` | Framed-source fallback |
| `index.ts` | `LovelyMermaid` | `render/1` entry, warnings, drop-last-line retry |

## Public API (mirrors lovely-mermaid)

```elixir
LovelyMermaid.render(src)     # => %{plain: [String], styled: [[span]], width: int, warnings: [String]} | nil
LovelyMermaid.diagram_kind(src)  # => :flowchart | :state | :class | :er | :sequence | nil
LovelyMermaid.source_box(src, width)
```

`render` returns `nil` for blank input, syntax errors, unsupported kinds and
diagrams refused by layout caps. Flowcharts warn about dropped statements;
the other grammars fail the whole diagram (with one retry dropping the final
line, so streaming sources stay on screen).

## Phases

1. **Foundation**: `Width` (table + grapheme width), `Graph` (model),
   `Labels` (ANSI helpers), `Canvas` (bit accumulation + finalize + blit) —
   each with tests generated against the TS behavior.
2. **Flowchart**: `Parse.parse_graph` + `Layout.layout_flowchart` (incl.
   subgraph groups), replacing the simplified engine in `apps/pie_tui`.
3. **State / class / ER**: the stricter grammars on top of the shared graph
   model and `layout_class`/`layout_flowchart` variants.
4. **Sequence**: `Parse.parse_sequence` + `LayoutSeq`.
5. **Entry**: `render`, warnings, retry-without-last-line, `SourceBox`,
   `Ansi`; then rewire `pie_tui` to depend on this package.

Golden outputs for tests are produced by the TS reference (lovely-mermaid's
`test/cases/` corpus) and inlined into `test/diagram_test.exs`.

## Rust cross-reference

The Rust original differs from the TS port in two spots worth checking while
porting: its box sizing counts code points (the TS port fixed this with
grapheme clusters), and it renders sequence/state diagrams only. Where TS and
Rust disagree, follow TS — it is the newer, bug-fixed line.
