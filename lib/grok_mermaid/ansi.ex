defmodule GrokMermaid.Ansi do
  @moduledoc """
  SGR parameter per semantic class, ported from grok-mermaid's ansi.ts.
  A class left out is printed unstyled.
  """

  @doc "Dim frame, plain labels, cyan connectors. Readable on light and dark."
  def default_theme do
    %{border: "2", edge: "36", edge_label: "2;36", title: "1"}
  end

  @doc """
  Render art to ANSI-coloured lines. A convenience over mapping
  `art.styled` yourself — reach for that directly when your TUI has its
  own styling model.
  """
  @spec to_ansi(map(), map()) :: [String.t()]
  def to_ansi(art, theme \\ default_theme()) do
    Enum.map(art.styled, fn row ->
      Enum.map_join(row, fn {text, cls} ->
        case Map.get(theme, cls) do
          nil -> text
          sgr -> "\e[#{sgr}m#{text}\e[0m"
        end
      end)
    end)
  end
end
