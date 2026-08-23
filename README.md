# GrokMermaid

Elixir port of [grok-mermaid](https://github.com/xl0/grok-mermaid) — render
Mermaid diagrams as Unicode box-drawing art for terminals.

```elixir
GrokMermaid.render("flowchart LR\n  A[Start] --> B[Done]")
# => %{plain: ["┌───────┐    ┌──────┐", "│ Start ├───▶│ Done │", ...],
#     styled: [...], width: 21, warnings: []}
```

## Installation

```elixir
def deps do
  [{:grok_mermaid, "~> 0.1"}]
end
```

## API

| Function | Returns |
|---|---|
| `GrokMermaid.render(src)` | `%{plain: [String.t()], styled: [[{text, class}]], width: pos_integer(), warnings: [String.t()]}` or `nil` |
| `GrokMermaid.diagram_kind(src)` | `:flowchart \| :state \| :class \| :er \| :sequence \| :pie \| :mindmap \| :timeline \| :gitgraph \| nil` |
| `GrokMermaid.SourceBox.source_box(src, max_width \\ nil)` | Framed source lines, for when a diagram won't render |
| `GrokMermaid.Ansi.to_ansi(art, theme \\ Ansi.default_theme())` | ANSI-coloured lines from `art.styled` |

`render/1` returns `nil` for blank input, syntax errors, unsupported kinds,
and diagrams refused by layout caps. Flowcharts report dropped statements in
`warnings`; the other grammars fail the whole diagram (with one retry
dropping the final line, so streaming sources stay on screen).

## Supported diagrams

`graph`/`flowchart` (including `subgraph`), `stateDiagram`, `classDiagram`,
`erDiagram`, `sequenceDiagram`, `pie`, `mindmap`, `timeline`, `gitGraph` —
mirroring grok-mermaid (lovely-mermaid).

## Porting notes

See [PORTING.md](PORTING.md) for the module map against the TypeScript and
Rust references.

## License

Apache-2.0 (same as the original grok-mermaid).
