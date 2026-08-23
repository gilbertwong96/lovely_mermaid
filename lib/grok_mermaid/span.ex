defmodule GrokMermaid.Span do
  @moduledoc """
  One run of same-role cells in a `styled` row.

  `text` is the run of characters, `role` is what the cells *are* (border,
  text, edge, edge label, title, or blank filler). Author-assigned
  `classes` (from `:::name` / `class A,B name`) and `href` (a `click`/
  `link` target) ride along when the node that painted the cells had them;
  otherwise they are `nil`. `Ansi.to_ansi/2` styles classed spans from
  `art.class_defs` and wraps linked spans in OSC 8 hyperlinks.
  """

  defstruct [:text, :role, classes: nil, href: nil]

  @type role :: :border | :text | :edge | :edge_label | :title | :none

  @type t :: %__MODULE__{
          text: String.t(),
          role: role(),
          classes: [String.t()] | nil,
          href: String.t() | nil
        }
end
