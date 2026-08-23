# LovelyMermaid

Elixir port of [lovely-mermaid](https://github.com/xl0/lovely-mermaid) — render
Mermaid diagrams as Unicode box-drawing art for terminals.

```elixir
LovelyMermaid.render("flowchart LR\n  A[Start] --> B[Done]")
# => %LovelyMermaid.Art{
#      plain: ["┌───────┐    ┌──────┐", "│ Start ├───▶│ Done │", ...],
#      styled: [...], width: 21, class_defs: %{}, warnings: []}
```

## Installation

```elixir
def deps do
  [{:lovely_mermaid, "~> 0.1"}]
end
```

## API

| Function                                                            | Returns                                                                                                   |
|---------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| `LovelyMermaid.render(src)`                                         | `%LovelyMermaid.Art{}` or `nil`                                                                           |
| `LovelyMermaid.diagram_kind(src)`                                   | `:flowchart \| :state \| :class \| :er \| :sequence \| :pie \| :mindmap \| :timeline \| :gitgraph \| nil` |
| `LovelyMermaid.SourceBox.source_box(src, max_width \\ nil)`         | `%LovelyMermaid.Art{}` — framed source lines, for when a diagram won't render                            |
| `LovelyMermaid.Ansi.to_ansi(art, theme \\ Ansi.default_theme())`    | `[String.t()]` — ANSI-coloured lines from `art.styled`                                                    |
| `LovelyMermaid.ClassStyle.resolve_class_style(classes, class_defs)` | `map() \| nil` — merged `classDef` style for a span                                                       |

Each `span` in `styled` is a `LovelyMermaid.Span` — `%Span{text, role}`
with `classes` (author-assigned names from `:::name` / `class A,B name`)
and `href` (a `click`/`link` target), both `nil` when the node had
neither. `to_ansi/2` styles classed spans from `art.class_defs` (best
effort) and wraps linked spans in OSC 8 hyperlinks.

A YAML frontmatter `title:` is drawn centred above the art in the `title`
role.

`render/1` returns `nil` for blank input, syntax errors, unsupported kinds,
and diagrams refused by layout caps. Flowcharts report dropped statements in
`warnings`; the other grammars fail the whole diagram (with one retry
dropping the final line, so streaming sources stay on screen).

## Supported diagrams

`graph`/`flowchart` (including `subgraph`), `stateDiagram`,
`classDiagram`, `erDiagram`, `sequenceDiagram`, `pie`, `mindmap`, `timeline`,
`gitGraph` — mirroring lovely-mermaid. Flowchart nodes accept
both the v1 shape brackets and the v2 `id@{shape: …, label: …}` syntax;
`state X { … }` composites nest as frames with `--` region dividers; diamond
nodes draw as double-line boxes with mixed edge tees.

## Porting notes

See [PORTING.md](PORTING.md) for the module map against the TypeScript and
Rust references.

## License

Apache-2.0 (same as the original lovely-mermaid).
