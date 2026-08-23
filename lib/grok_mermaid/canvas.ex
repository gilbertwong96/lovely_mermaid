defmodule GrokMermaid.Canvas do
  @moduledoc """
  A grid of cells, ported from grok-mermaid's canvas.ts.

  Edges accumulate as direction bits rather than glyphs so that crossings
  and junctions resolve correctly whatever order they are drawn in;
  `finalize_mask/1` turns the accumulated bits into box-drawing characters
  at the end. `occupied` marks cells claimed by a box, which edge bits must
  not overwrite.
  """

  alias GrokMermaid.Width

  # Sentinel occupying the trailing column of a wide glyph. Never emitted:
  # the line builder skips it, so a CJK character claims two cells of
  # layout but contributes one character of output.
  @cont <<0>>

  # Connection direction bits, combined into a box-drawing glyph by
  # `mask_char/1`.
  @u 1
  @d 2
  @l 4
  @r 8

  # Line styles, tracked per cell so crossing edges keep their own stroke.
  @sty_dot 1
  @sty_thick 2
  @sty_solid 4

  # Precomputed direction combinations (module attributes are constants).
  @ud Bitwise.bor(@u, @d)
  @lr Bitwise.bor(@l, @r)
  @dr Bitwise.bor(@d, @r)
  @dl Bitwise.bor(@d, @l)
  @ur Bitwise.bor(@u, @r)
  @ul Bitwise.bor(@u, @l)
  @udr Bitwise.bor(Bitwise.bor(@u, @d), @r)
  @udl Bitwise.bor(Bitwise.bor(@u, @d), @l)
  @dlr Bitwise.bor(Bitwise.bor(@d, @l), @r)
  @ulr Bitwise.bor(Bitwise.bor(@u, @l), @r)

  @dotted %{"─" => "╌", "│" => "╎"}

  @thick %{
    "─" => "━",
    "│" => "┃",
    "┌" => "┏",
    "┐" => "┓",
    "└" => "┗",
    "┘" => "┛",
    "├" => "┣",
    "┤" => "┫",
    "┬" => "┳",
    "┴" => "┻",
    "┼" => "╋"
  }

  @flip_v %{
    "┌" => "└",
    "└" => "┌",
    "┐" => "┘",
    "┘" => "┐",
    "┏" => "┗",
    "┗" => "┏",
    "┓" => "┛",
    "┛" => "┓",
    "╭" => "╰",
    "╰" => "╭",
    "╮" => "╯",
    "╯" => "╮",
    "┬" => "┴",
    "┴" => "┬",
    "┳" => "┻",
    "┻" => "┳",
    "▼" => "▲",
    "▲" => "▼",
    "▽" => "△",
    "△" => "▽"
  }

  @flip_h %{
    "┌" => "┐",
    "┐" => "┌",
    "└" => "┘",
    "┘" => "└",
    "┏" => "┓",
    "┓" => "┏",
    "┗" => "┛",
    "┛" => "┗",
    "╭" => "╮",
    "╮" => "╭",
    "╰" => "╯",
    "╯" => "╰",
    "├" => "┤",
    "┤" => "├",
    "┣" => "┫",
    "┫" => "┣",
    "▶" => "◄",
    "◄" => "▶",
    "▷" => "◁",
    "◁" => "▷"
  }

  defstruct w: 0,
            h: 0,
            ch: %{},
            cls: %{},
            mask: %{},
            style: %{},
            occupied: %{},
            cur_style: @sty_solid

  @type t :: %__MODULE__{
          w: non_neg_integer(),
          h: non_neg_integer(),
          ch: map(),
          cls: map(),
          mask: map(),
          style: map(),
          occupied: map(),
          cur_style: 1 | 2 | 4
        }

  @doc "Create a canvas of `w` by `h` cells."
  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(w, h) do
    %__MODULE__{w: w, h: h}
  end

  @doc "Line style constants for `cur_style`."
  def style_dot, do: @sty_dot
  def style_thick, do: @sty_thick
  def style_solid, do: @sty_solid

  @doc "Set a cell's character and class (out of bounds is a no-op)."
  @spec set(t(), integer(), integer(), String.t(), atom()) :: t()
  def set(%__MODULE__{w: w, h: h} = c, x, y, char, cls) do
    if x >= w or y >= h do
      c
    else
      i = y * w + x
      %{c | ch: Map.put(c.ch, i, char), cls: Map.put(c.cls, i, cls)}
    end
  end

  @doc """
  Accumulate direction bits on a free cell.

  `cls` is the class to claim the cell for; `border` cells are never
  reclassified, so a connector meeting a box keeps the box's styling.
  """
  @spec add_bits(t(), integer(), integer(), non_neg_integer(), atom()) :: t()
  def add_bits(%__MODULE__{w: w, h: h} = c, x, y, bits, cls \\ :edge) do
    if x >= w or y >= h do
      c
    else
      i = y * w + x

      if Map.get(c.occupied, i) do
        c
      else
        %{
          c
          | mask: Map.update(c.mask, i, bits, &Bitwise.bor(&1, bits)),
            style: Map.update(c.style, i, c.cur_style, &Bitwise.bor(&1, c.cur_style)),
            cls: if(Map.get(c.cls, i) != :border, do: Map.put(c.cls, i, cls), else: c.cls)
        }
      end
    end
  end

  @doc """
  Add direction bits even to an occupied cell, so an edge can meet a border.
  """
  @spec junction(t(), integer(), integer(), non_neg_integer()) :: t()
  def junction(%__MODULE__{w: w, h: h} = c, x, y, bits) do
    if x >= w or y >= h do
      c
    else
      i = y * w + x
      cls = if Map.get(c.cls, i) != :border, do: :edge, else: :border

      %{
        c
        | mask: Map.update(c.mask, i, bits, &Bitwise.bor(&1, bits)),
          cls: Map.put(c.cls, i, cls)
      }
    end
  end

  @doc "Claim a cell for a box, which edge bits must not overwrite."
  @spec occupy(t(), integer(), integer()) :: t()
  def occupy(%__MODULE__{w: w, h: h} = c, x, y) do
    if x >= w or y >= h do
      c
    else
      %{c | occupied: Map.put(c.occupied, y * w + x, 1)}
    end
  end

  @doc """
  Stamp a finished sub-canvas (a subgraph frame's contents) at an offset.
  The stamped cells are marked occupied.
  """
  @spec blit(t(), t(), integer(), integer()) :: t()
  def blit(%__MODULE__{w: w, h: h} = c, sub, ox, oy) do
    Enum.reduce(0..(sub.h - 1), c, fn sy, c ->
      Enum.reduce(0..(sub.w - 1), c, fn sx, c ->
        x = ox + sx
        y = oy + sy

        if x < w and y < h do
          si = sy * sub.w + sx
          di = y * w + x

          %{
            c
            | ch: Map.put(c.ch, di, Map.get(sub.ch, si, " ")),
              cls: Map.put(c.cls, di, Map.get(sub.cls, si, :none)),
              style: Map.put(c.style, di, Map.get(sub.style, si, 4)),
              occupied: Map.put(c.occupied, di, 1)
          }
        else
          c
        end
      end)
    end)
  end

  @doc "Draw a vertical segment between `y0` and `y1` at column `x`."
  @spec seg_v(t(), integer(), integer(), integer()) :: t()
  def seg_v(c, x, y0, y1) do
    a = min(y0, y1)
    b = max(y0, y1)

    Enum.reduce(a..b, c, fn y, c ->
      bits = if(y > a, do: @u, else: 0) |> Bitwise.bor(if(y < b, do: @d, else: 0))
      add_bits(c, x, y, bits)
    end)
  end

  @doc "Draw a horizontal line between `x0` and `x1` at row `y`."
  @spec seg_h(t(), integer(), integer(), integer()) :: t()
  def seg_h(c, y, x0, x1) do
    a = min(x0, x1)
    b = max(x0, x1)

    Enum.reduce(a..b, c, fn x, c ->
      bits = if(x > a, do: @l, else: 0) |> Bitwise.bor(if(x < b, do: @r, else: 0))
      add_bits(c, x, y, bits)
    end)
  end

  @doc "Resolve accumulated direction bits into glyphs, honouring line style."
  @spec finalize_mask(t()) :: t()
  def finalize_mask(c) do
    ch =
      Enum.reduce(c.mask, c.ch, fn {i, mask}, ch ->
        if Map.get(ch, i, " ") == " ", do: Map.put(ch, i, styled_glyph(c, i, mask)), else: ch
      end)

    %{c | ch: ch}
  end

  defp styled_glyph(c, i, mask) do
    glyph = mask_char(mask)

    case Map.get(c.style, i) do
      @sty_dot -> dotted_char(glyph)
      @sty_thick -> thick_char(glyph)
      _ -> glyph
    end
  end

  @doc """
  Mirror top-to-bottom for `BT`. Rows reorder but within-row text does not,
  so labels stay readable; box-drawing glyphs flip to match.
  """
  @spec flip_vertical(t()) :: t()
  def flip_vertical(c) do
    c = swap_rows(c)

    %{c | ch: Map.new(c.ch, fn {i, g} -> {i, flip_glyph_v(g)} end)}
  end

  @doc """
  Mirror left-to-right for `RL`. Mirroring reverses each row, so after
  flipping glyphs each text/label run is reversed back to reading order.
  """
  @spec flip_horizontal(t()) :: t()
  def flip_horizontal(c) do
    c = reverse_cols(c)

    c = %{c | ch: Map.new(c.ch, fn {i, g} -> {i, flip_glyph_h(g)} end)}

    # reverse text runs (text / edgeLabel classes) back to reading order
    Enum.reduce(0..(c.h - 1), c, &reverse_text_run(&2, &1))
  end

  @doc """
  Group each row into runs of one class, dropping wide-glyph continuations.
  Returns `{plain, styled, width}`; blank leading/trailing rows are trimmed.
  """
  @spec to_lines(t()) :: {[String.t()], [[{String.t(), atom()}]], non_neg_integer()}
  def to_lines(c) do
    rows = Enum.map(0..(c.h - 1), fn y -> row_lines(c, y) end)
    rows = drop_blank(rows)
    plain = Enum.map(rows, &elem(&1, 0))
    styled = Enum.map(rows, &elem(&1, 1))
    widths = Enum.map(rows, &elem(&1, 2))
    {plain, styled, Enum.max(widths, fn -> 0 end)}
  end

  defp row_lines(c, y) do
    last = last_painted(c, y)
    {plain, spans} = build_row(c, y, last)
    {plain, spans, last}
  end

  defp last_painted(c, y) do
    Enum.reduce_while((c.w - 1)..0//-1, 0, fn x, _acc ->
      if Map.get(c.ch, y * c.w + x, " ") != " " do
        {:halt, x + 1}
      else
        {:cont, 0}
      end
    end)
  end

  defp build_row(c, y, last) do
    {plain, spans, run, run_cls} =
      Enum.reduce(0..(last - 1)//1, {"", [], "", :none}, fn x, acc ->
        i = y * c.w + x
        char = Map.get(c.ch, i, " ")
        cls = Map.get(c.cls, i, :none)
        {plain, spans, run, run_cls} = acc

        cond do
          char == @cont ->
            acc

          cls != run_cls and run != "" ->
            {plain <> char, spans ++ [{run, run_cls}], char, cls}

          true ->
            {plain <> char, spans, run <> char, cls}
        end
      end)

    spans = if run != "", do: spans ++ [{run, run_cls}], else: spans
    {String.trim_trailing(plain, " "), spans}
  end

  defp drop_blank(rows) do
    rows
    |> drop_leading_blank()
    |> Enum.reverse()
    |> drop_leading_blank()
    |> Enum.reverse()
  end

  defp drop_leading_blank(rows) do
    case rows do
      [{plain, _, _} | rest] when plain == "" -> drop_leading_blank(rest)
      _ -> rows
    end
  end

  # --- helpers ---------------------------------------------------------

  defp swap_rows(c) do
    Enum.reduce(0..(div(c.h, 2) - 1)//1, c, fn y, c ->
      y2 = c.h - 1 - y

      Enum.reduce(0..(c.w - 1), c, fn x, c ->
        i = y * c.w + x
        j = y2 * c.w + x
        swap_cells(c, i, j)
      end)
    end)
  end

  defp reverse_cols(c) do
    Enum.reduce(0..(c.h - 1), c, fn y, c ->
      Enum.reduce(0..(div(c.w, 2) - 1)//1, c, fn x, c ->
        x2 = c.w - 1 - x
        i = y * c.w + x
        j = y * c.w + x2
        swap_cells(c, i, j)
      end)
    end)
  end

  # Reverse each text/edgeLabel run on row `y` so labels read normally
  # after the horizontal mirror.
  defp reverse_text_run(c, y) do
    Enum.reduce(0..(c.w - 1), c, fn x, c ->
      cls = Map.get(c.cls, y * c.w + x, :none)

      if cls in [:text, :edgeLabel] and Map.get(c.cls, y * c.w + (x - 1), :none) != cls do
        run_end = run_end(c, y, x, cls)
        reverse_cells(c, y, x, run_end)
      else
        c
      end
    end)
  end

  defp run_end(c, y, x, cls) do
    Enum.reduce_while(x..(c.w - 1), x, fn xx, _acc ->
      if Map.get(c.cls, y * c.w + xx, :none) == cls do
        {:cont, xx + 1}
      else
        {:halt, xx}
      end
    end)
  end

  defp reverse_cells(c, y, start, run_end) do
    Enum.reduce(0..(div(run_end - start, 2) - 1)//1, c, fn k, c ->
      i = y * c.w + (start + k)
      j = y * c.w + (run_end - 1 - k)
      swap_cells(c, i, j)
    end)
  end

  # Read both cell values before writing, so the swap is lossless.
  defp swap_cells(c, i, j) do
    vi = Map.get(c.ch, i, " ")
    vj = Map.get(c.ch, j, " ")
    ci = Map.get(c.cls, i, :none)
    cj = Map.get(c.cls, j, :none)
    %{c | ch: Map.put(Map.put(c.ch, i, vj), j, vi), cls: Map.put(Map.put(c.cls, i, cj), j, ci)}
  end

  @doc "Paint `text` at `x, y`, one grapheme cluster per cell."
  @spec draw_text(t(), String.t(), integer(), integer(), atom()) :: t()
  def draw_text(canvas, text, x, y, cls) do
    {canvas, _} =
      Enum.reduce(Width.measured(text), {canvas, x}, fn {cluster, cw}, {canvas, cur} ->
        paint_cluster(canvas, cluster, cw, cur, y, cls, false)
      end)

    canvas
  end

  # Paint one cluster at `cur`, optionally clearing edge bits underneath.
  defp paint_cluster(canvas, _cluster, 0, cur, _y, _cls, _over) do
    {canvas, cur}
  end

  defp paint_cluster(canvas, cluster, cw, cur, y, cls, over) do
    canvas = clear_under(canvas, cur, y, cw, over)
    canvas = set(canvas, cur, y, cluster, cls)

    canvas =
      Enum.reduce(1..(cw - 1)//1, canvas, fn k, canvas ->
        set(canvas, cur + k, y, @cont, cls)
      end)

    {canvas, cur + cw}
  end

  defp clear_under(canvas, _cur, _y, _cw, false), do: canvas

  defp clear_under(canvas, cur, y, cw, true) do
    Enum.reduce(0..(cw - 1), canvas, fn k, canvas ->
      if cur + k < canvas.w and y < canvas.h do
        %{canvas | mask: Map.delete(canvas.mask, y * canvas.w + cur + k)}
      else
        canvas
      end
    end)
  end

  @doc """
  Paint `text` at `x, y`, clearing any edge bits underneath first. Used
  where text sits on top of a drawn line and must win over it.
  """
  @spec draw_text_over_edges(t(), String.t(), integer(), integer(), atom()) :: t()
  def draw_text_over_edges(canvas, text, x, y, cls) do
    {canvas, _} =
      Enum.reduce(Width.measured(text), {canvas, x}, fn {cluster, cw}, {canvas, cur} ->
        paint_cluster(canvas, cluster, cw, cur, y, cls, true)
      end)

    canvas
  end

  @mask_glyphs %{
    0 => " ",
    @u => "│",
    @d => "│",
    @ud => "│",
    @l => "─",
    @r => "─",
    @lr => "─",
    @dr => "┌",
    @dl => "┐",
    @ur => "└",
    @ul => "┘",
    @udr => "├",
    @udl => "┤",
    @dlr => "┬",
    @ulr => "┴"
  }

  @doc "Box-drawing glyph for accumulated direction bits."
  @spec mask_char(non_neg_integer()) :: String.t()
  def mask_char(mask), do: Map.get(@mask_glyphs, mask, "┼")

  defp dotted_char(c), do: Map.get(@dotted, c, c)
  defp thick_char(c), do: Map.get(@thick, c, c)

  @doc "Flip a glyph for vertical mirroring (no-op unless it has a mapping)."
  @spec flip_glyph_v(String.t()) :: String.t()
  def flip_glyph_v(c), do: Map.get(@flip_v, c, c)

  @doc "Flip a glyph for horizontal mirroring."
  @spec flip_glyph_h(String.t()) :: String.t()
  def flip_glyph_h(c), do: Map.get(@flip_h, c, c)
end
