defmodule GrokMermaid.Art do
  @moduledoc """
  What `GrokMermaid.render/1` (and `GrokMermaid.SourceBox.source_box/2`)
  produce: the finished picture plus the metadata a caller needs.

  `plain` is the art as lines of characters; `styled` is the same art
  split into `GrokMermaid.Span` runs for theming; `width` is the column
  count the layout settled on; `class_defs` holds the `classDef`
  declarations parsed from the source (`Ansi.to_ansi/2` styles spans
  against them); `warnings` lists statements the parser gave up on —
  advisory only, never a reason to withhold the art.
  """

  alias GrokMermaid.Span

  defstruct [:plain, :styled, :width, :class_defs, :warnings]

  @type t :: %__MODULE__{
          plain: [String.t()],
          styled: [[Span.t()]],
          width: non_neg_integer(),
          class_defs: map(),
          warnings: [String.t()]
        }
end
