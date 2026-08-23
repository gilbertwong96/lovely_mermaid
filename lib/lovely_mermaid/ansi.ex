defmodule LovelyMermaid.Ansi do
  @moduledoc """
  SGR parameter per semantic class, ported from grok-mermaid's ansi.ts.
  A class left out is printed unstyled.
  """

  alias LovelyMermaid.ClassStyle

  @esc <<27>>
  @osc8 "#{@esc}]8;;"
  @st "#{@esc}\\"

  @doc "Dim frame, plain labels, cyan connectors. Readable on light and dark."
  def default_theme do
    %{border: "2", edge: "36", edge_label: "2;36", title: "1"}
  end

  @doc """
  The truecolor SGR a class style gives a span of the given role, or nil
  when the style says nothing about it (fall back to the theme). `stroke`
  colors borders, `color` text; `fill` backs every painted cell, with a
  black/white foreground picked for contrast when none was declared. A
  style that colors nothing for this role keeps `fallback` (the theme's
  SGR), so a bold-only class bolds the themed look instead of replacing it.
  """
  @spec class_sgr(map(), atom(), String.t() | nil) :: String.t() | nil
  def class_sgr(st, role, fallback \\ nil) do
    p =
      cond do
        role == :border ->
          [st[:stroke] || st[:color], st[:fill]]

        role == :edge ->
          [nil, st[:fill]]

        true ->
          [st[:color], st[:fill]]
      end

    [fg, fill] = p
    backed = fg || if(st[:fill] == nil, do: nil, else: ClassStyle.contrast_on(st[:fill]))

    params =
      []
      |> maybe_push(if(backed != nil, do: rgb(backed, 38)))
      |> maybe_push(if(fill != nil, do: rgb(fill, 48)))

    params =
      if params == [] and fallback != nil do
        params ++ [fallback]
      else
        params
      end

    params = if st[:bold] == true, do: ["1" | params], else: params

    if params == [] do
      nil
    else
      Enum.join(params, ";")
    end
  end

  @doc """
  Render art to ANSI-coloured lines. Spans that carry author classes are
  styled from `art.class_defs` (best effort — see `ClassStyle`), overriding
  the role theme; everything else follows `theme`.

  A convenience over mapping `art.styled` yourself — reach for that directly
  when your TUI has its own styling model.
  """
  @spec to_ansi(map(), map()) :: [String.t()]
  def to_ansi(art, theme \\ default_theme()) do
    class_defs = Map.get(art, :class_defs, %{})

    Enum.map(art.styled, fn row ->
      Enum.map_join(row, fn span ->
        text = span.text
        cls = ClassStyle.resolve_class_style(span.classes, class_defs)

        sgr =
          if cls != nil,
            do: class_sgr(cls, span.role, Map.get(theme, span.role)),
            else: Map.get(theme, span.role)

        colored = if sgr == nil, do: text, else: "\e[#{sgr}m#{text}\e[0m"

        case span.href do
          nil -> colored
          href -> "#{@osc8}#{href}#{@st}#{colored}#{@osc8}#{@st}"
        end
      end)
    end)
  end

  defp rgb(hex, sgr) do
    parts = [1, 3, 5] |> Enum.map(fn i -> String.to_integer(String.slice(hex, i, 2), 16) end)
    "#{sgr};2;#{Enum.join(parts, ";")}"
  end

  defp maybe_push(list, nil), do: list
  defp maybe_push(list, v), do: list ++ [v]
end
