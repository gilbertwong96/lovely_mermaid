defmodule GrokMermaid.Layout do
  @moduledoc """
  Graph layout: rank, order, place, route, draw. Ported from
  grok-mermaid's layout.ts.

  Follows the Sugiyama outline — assign ranks along the flow axis, reorder
  within ranks to cut crossings, then relax positions on the cross axis so
  chains stay straight. Edges between adjacent ranks share horizontal "bus"
  rows; everything else is routed around the diagram through vertical
  "lanes". `BT` and `RL` reuse the `TD`/`LR` layouts and flip the finished
  canvas, so text never ends up mirrored.
  """

  alias GrokMermaid.{Canvas, Labels, Width}

  # Cells of padding between a box border and its text.
  @pad 1
  # Minimum horizontal / vertical space between boxes.
  @gap_x 3
  @gap_y 2
  # Refuse to allocate a canvas larger than this many cells.
  @max_canvas_cells 2_097_152

  @type placed :: %{
          x: integer(),
          y: integer(),
          w: integer(),
          h: integer(),
          cx: integer(),
          cy: integer(),
          rank: integer()
        }

  @type sizes :: %{
          boxW: [non_neg_integer()],
          boxH: [non_neg_integer()],
          layW: [non_neg_integer()],
          layH: [non_neg_integer()],
          extraH: [non_neg_integer()],
          selfLabelW: [non_neg_integer()]
        }

  @type route_plan :: %{
          canvas_w: non_neg_integer(),
          canvas_h: non_neg_integer(),
          band_end: %{},
          edge_bus: %{},
          lane_base: non_neg_integer(),
          edge_lane: %{}
        }

  @type extra ::
          %{kind: :plain}
          | %{kind: :frame, sub: Canvas.t()}
          | %{kind: :compartments, sections: [[String.t()]]}

  defp sat(a, b), do: max(0, a - b)
  defp half(n), do: div(n, 2)

  # ----------------------------------------------------------------- ranking

  @doc """
  Longest-path ranking over the graph's DAG.

  Back edges (those closing a cycle) are excluded by a DFS colouring pass,
  so `A --> B --> C --> A` still ranks 0, 1, 2 rather than diverging.
  """
  @spec compute_ranks(GrokMermaid.Graph.t()) :: %{non_neg_integer() => non_neg_integer()}
  def compute_ranks(graph) do
    n = length(graph.nodes)
    ids = 0..(n - 1)

    {children, indeg} =
      Enum.reduce(graph.edges, {Map.new(ids, &{&1, []}), Map.new(ids, &{&1, 0})}, fn e,
                                                                                     {ch, id} ->
        if e.from != e.to do
          {Map.update!(ch, e.from, &(&1 ++ [e.to])), Map.update!(id, e.to, &(&1 + 1))}
        else
          {ch, id}
        end
      end)

    roots = Enum.filter(ids, &(Map.get(indeg, &1) == 0))
    {dag, order} = dfs_dag(n, roots ++ Enum.to_list(ids), children)

    # Postorder reversed: ranks grow from roots to leaves.
    Enum.reduce(Enum.reverse(order), Map.new(ids, &{&1, 0}), fn u, rank ->
      Enum.reduce(Map.get(dag, u, []), rank, fn v, rank ->
        Map.update(rank, v, Map.get(rank, u, 0) + 1, fn r ->
          max(r, Map.get(rank, u, 0) + 1)
        end)
      end)
    end)
  end

  defp dfs_dag(n, starts, children) do
    {_color, dag, order} =
      Enum.reduce(starts, {Map.new(0..(n - 1), &{&1, 0}), Map.new(0..(n - 1), &{&1, []}), []}, fn
        start, {color, dag, order} ->
          if Map.get(color, start) != 0 do
            {color, dag, order}
          else
            color = Map.put(color, start, 1)
            {color, dag, order} = dfs_loop([{start, 0}], {color, dag, order}, children)
            {color, dag, [start | order]}
          end
      end)

    # order is reversed postorder; reverse once more for true postorder
    {dag, Enum.reverse(order)}
  end

  defp dfs_loop([], {color, dag, order}, _children), do: {color, dag, order}

  defp dfs_loop([{u, i} | stack], {color, dag, order}, children) do
    cs = Map.get(children, u, [])

    if i < length(cs) do
      v = Enum.at(cs, i)

      if Map.get(color, v) == 1 do
        # grey: a back edge, ignore it
        dfs_loop([{u, i + 1} | stack], {color, dag, order}, children)
      else
        dag = Map.update!(dag, u, &(&1 ++ [v]))

        if Map.get(color, v) == 0 do
          color = Map.put(color, v, 1)
          dfs_loop([{v, 0}, {u, i + 1} | stack], {color, dag, order}, children)
        else
          dfs_loop([{u, i + 1} | stack], {color, dag, order}, children)
        end
      end
    else
      color = Map.put(color, u, 2)
      dfs_loop(stack, {color, dag, [u | order]}, children)
    end
  end

  # ------------------------------------------------------------------- order

  @doc """
  Reorder nodes within each rank to minimise edge crossings (barycenter
  sweeps): alternate down/up passes sort each rank by the mean position of
  its neighbours, keeping whichever ordering crossed least.
  """
  @spec order_ranks([[non_neg_integer()]], [GrokMermaid.Graph.edge()], %{
          non_neg_integer() => non_neg_integer()
        }) :: [[non_neg_integer()]]
  def order_ranks(by_rank, edges, ranks) do
    n = map_size(ranks)

    if not match?([_, _ | _], by_rank) or n < 3 do
      by_rank
    else
      {parents, children} = rank_neighbours(edges, ranks)
      pos = rank_positions(by_rank)
      best = by_rank
      best_crossings = count_crossings(edges, ranks, pos)

      if best_crossings == 0 do
        by_rank
      else
        {best, _} =
          Enum.reduce(1..8, {best, best_crossings}, fn it, {best, best_crossings} ->
            rows =
              if rem(it, 2) == 1 do
                Enum.drop(by_rank, 1)
              else
                by_rank |> Enum.drop(-1) |> Enum.reverse()
              end

            neigh = if rem(it, 2) == 1, do: parents, else: children

            pos =
              Enum.reduce(rows, pos, fn row, pos ->
                new_row = sort_by_barycenter(row, neigh, pos)
                by_rank = replace_row(by_rank, row, new_row)
                rank_positions(by_rank)
              end)

            crossings = count_crossings(edges, ranks, pos)

            if crossings < best_crossings do
              {by_rank, crossings}
            else
              {best, best_crossings}
            end
          end)

        best
      end
    end
  end

  defp rank_neighbours(edges, ranks) do
    Enum.reduce(edges, {%{}, %{}}, fn e, {parents, children} ->
      if e.from != e.to and Map.get(ranks, e.to, 0) > Map.get(ranks, e.from, 0) do
        parents = Map.update(parents, e.to, [e.from], &(&1 ++ [e.from]))
        children = Map.update(children, e.from, [e.to], &(&1 ++ [e.to]))
        {parents, children}
      else
        {parents, children}
      end
    end)
  end

  defp rank_positions(by_rank) do
    Enum.with_index(by_rank)
    |> Enum.reduce(%{}, fn {row, _ri}, pos ->
      Enum.with_index(row)
      |> Enum.reduce(pos, fn {v, i}, pos -> Map.put(pos, v, i) end)
    end)
  end

  defp sort_by_barycenter(row, neigh, pos) do
    row
    |> Enum.map(fn v ->
      key =
        case Map.get(neigh, v, []) do
          [] -> Map.get(pos, v, 0)
          ns -> Enum.sum(Enum.map(ns, &Map.get(pos, &1, 0))) / length(ns)
        end

      {key, v}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp replace_row(by_rank, row, new_row) do
    Enum.map(by_rank, fn r -> if r == row, do: new_row, else: r end)
  end

  @doc "Count crossings between adjacent ranks."
  @spec count_crossings([GrokMermaid.Graph.edge()], %{non_neg_integer() => non_neg_integer()}, %{
          non_neg_integer() => non_neg_integer()
        }) :: non_neg_integer()
  def count_crossings(edges, ranks, pos) do
    adjacent =
      Enum.filter(edges, fn e ->
        e.from != e.to and Map.get(ranks, e.to, 0) == Map.get(ranks, e.from, 0) + 1
      end)
      |> Enum.map(fn e ->
        {Map.get(ranks, e.from, 0), Map.get(pos, e.from, 0), Map.get(pos, e.to, 0)}
      end)

    adjacent
    |> Enum.with_index()
    |> Enum.reduce(0, fn {{rank_a, pa, qa}, i}, acc ->
      Enum.drop(adjacent, i + 1)
      |> Enum.reduce(acc, fn {rank_b, pb, qb}, acc ->
        if rank_a == rank_b and ((pa < pb and qa > qb) or (pa > pb and qa < qb)) do
          acc + 1
        else
          acc
        end
      end)
    end)
  end

  @doc """
  Assign a cross-axis centre to every node so nodes line up under their
  neighbours: each node drifts toward the average of its neighbours while
  ranks keep their order and boxes keep `sep` between them.
  """
  @spec assign_positions(
          [[non_neg_integer()]],
          [non_neg_integer()],
          non_neg_integer(),
          [GrokMermaid.Graph.edge()],
          %{non_neg_integer() => non_neg_integer()}
        ) :: %{non_neg_integer() => non_neg_integer()}
  def assign_positions(by_rank, size, sep, edges, ranks) do
    {parents, children} = rank_neighbours(edges, ranks)

    pos =
      Enum.reduce(by_rank, %{}, fn row, pos ->
        {pos, _} =
          Enum.reduce(row, {pos, 0}, fn v, {pos, x} ->
            h = Enum.at(size, v) / 2
            {Map.put(pos, v, x + h), x + 2 * h + sep}
          end)

        pos
      end)

    pos =
      Enum.reduce(1..10, pos, fn it, pos ->
        rows = if rem(it, 2) == 1, do: by_rank, else: Enum.reverse(by_rank)
        neigh = if rem(it, 2) == 1, do: parents, else: children
        Enum.reduce(rows, pos, fn row, pos -> relax_rank(row, neigh, pos, size, sep) end)
      end)

    min_left =
      Enum.reduce(0..(length(size) - 1), :infinity, fn v, acc ->
        min(acc, Map.get(pos, v, 0) - Enum.at(size, v) / 2)
      end)

    min_left = if min_left == :infinity, do: 0, else: min_left

    Map.new(0..(length(size) - 1), fn v -> {v, max(0, round(Map.get(pos, v, 0) - min_left))} end)
  end

  defp relax_rank(nodes, neigh, pos, size, sep) do
    if nodes == [] do
      pos
    else
      desired =
        Map.new(nodes, fn v ->
          case Map.get(neigh, v, []) do
            [] -> {v, Map.get(pos, v, 0)}
            ns -> {v, Enum.sum(Enum.map(ns, &Map.get(pos, &1, 0))) / length(ns)}
          end
        end)

      half_of = fn i -> Enum.at(size, Enum.at(nodes, i)) / 2 end
      n = length(nodes)

      left =
        Enum.reduce(0..(n - 1), %{}, fn i, left ->
          v = Map.get(desired, Enum.at(nodes, i))
          l = if i == 0, do: v, else: Map.get(left, i - 1) + half_of.(i - 1) + sep + half_of.(i)
          Map.put(left, i, max(v, l))
        end)

      right =
        Enum.reduce((n - 1)..0//-1, %{}, fn i, right ->
          v = Map.get(desired, Enum.at(nodes, i))

          r =
            if i == n - 1 do
              v
            else
              Map.get(right, i + 1) - half_of.(i + 1) - sep - half_of.(i)
            end

          Map.put(right, i, min(v, r))
        end)

      {pos, _} =
        Enum.reduce(0..(n - 1), {pos, nil}, fn i, {pos, _prev} ->
          p = (Map.get(left, i) + Map.get(right, i)) / 2

          p =
            if i > 0 do
              min_p = Map.get(pos, Enum.at(nodes, i - 1)) + half_of.(i - 1) + sep + half_of.(i)
              max(p, min_p)
            else
              p
            end

          {Map.put(pos, Enum.at(nodes, i), p), p}
        end)

      pos
    end
  end

  # ----------------------------------------------------------------- tracks

  @doc """
  Pack spans into as few parallel tracks as possible.

  Two spans share a track when they are two cells apart, or when they share
  an endpoint — edges fanning out of one node deliberately reuse a single
  row so a merge draws one arrowhead rather than a stack of them.
  """
  @spec assign_tracks([{integer(), integer(), integer(), integer(), integer()}]) ::
          {[{integer(), integer()}], non_neg_integer()}
  def assign_tracks(spans) do
    sorted = Enum.sort_by(spans, fn {a, b, c, d, e} -> {a, b, c, d, e} end)

    {tracks, assigned} =
      Enum.reduce(sorted, {[], []}, fn {s, e, f, t, idx}, {tracks, assigned} ->
        case find_slot(tracks, s, e, f, t) do
          nil ->
            {tracks ++ [[{s, e, f, t}]], assigned ++ [{idx, length(tracks)}]}

          slot ->
            tracks = List.update_at(tracks, slot, fn members -> members ++ [{s, e, f, t}] end)
            {tracks, assigned ++ [{idx, slot}]}
        end
      end)

    {assigned, length(tracks)}
  end

  defp find_slot(tracks, s, e, f, t) do
    Enum.find_index(tracks, fn members ->
      Enum.all?(members, fn {s2, e2, f2, t2} ->
        e2 + 2 <= s or e + 2 <= s2 or f2 == f or t2 == t
      end)
    end)
  end

  # Edges from rank `r` to `r + 1` that must jog sideways, so need a bus row.
  defp bus_spans(graph, ranks, centers, r, exact) do
    graph.edges
    |> Enum.with_index()
    |> Enum.reduce([], fn {e, i}, out ->
      cf = Map.get(centers, e.from, 0)
      ct = Map.get(centers, e.to, 0)
      jogs = if exact, do: cf != ct, else: abs(cf - ct) > 1

      if e.from != e.to and Map.get(ranks, e.from, 0) == r and Map.get(ranks, e.to, 0) == r + 1 and
           jogs do
        out ++ [{min(cf, ct), max(cf, ct), e.from, e.to, i}]
      else
        out
      end
    end)
  end

  # Edges skipping a rank or running backwards; these go around in a lane.
  defp lane_spans(graph, ranks, placed, vertical) do
    graph.edges
    |> Enum.with_index()
    |> Enum.reduce([], fn {e, i}, acc ->
      if e.from == e.to or Map.get(ranks, e.to, 0) == Map.get(ranks, e.from, 0) + 1 do
        acc
      else
        pf = Map.fetch!(placed, e.from)
        pt = Map.fetch!(placed, e.to)
        a = if vertical, do: min(pf.cy, pt.cy), else: min(pf.cx, pt.cx)
        b = if vertical, do: max(pf.cy, pt.cy), else: max(pf.cx, pt.cx)
        acc ++ [{a, b, e.from, e.to, i}]
      end
    end)
  end

  # ----------------------------------------------------------------- placement

  defp assign_bus_tracks(graph, ranks, centers, vertical, max_rank) do
    Enum.reduce(0..(max_rank - 1)//1, {%{}, %{}}, fn r, {edge_bus, bus_tracks} ->
      spans = bus_spans(graph, ranks, centers, r, vertical)

      if spans == [] do
        {edge_bus, bus_tracks}
      else
        {assigned, count} = assign_tracks(spans)

        edge_bus =
          Enum.reduce(assigned, edge_bus, fn {idx, slot}, acc -> Map.put(acc, idx, slot) end)

        {edge_bus, Map.put(bus_tracks, r, count)}
      end
    end)
  end

  defp assign_lane_tracks(graph, ranks, placed, vertical, base) do
    case lane_spans(graph, ranks, placed, vertical) do
      [] ->
        {%{}, 0, base}

      lanes ->
        {assigned, count} = assign_tracks(lanes)

        edge_lane = Map.new(assigned)

        {edge_lane, base + 1, base + 1 + count}
    end
  end

  defp place_td(ranks, max_rank, by_rank, sizes, graph, placed) do
    centers = assign_positions(by_rank, sizes.layW, @gap_x, graph.edges, ranks)

    {edge_bus, bus_tracks} = assign_bus_tracks(graph, ranks, centers, false, max_rank)

    rank_h =
      Enum.map(by_rank, fn row ->
        if row == [] do
          3
        else
          row |> Enum.map(&(Enum.at(sizes.boxH, &1) + Enum.at(sizes.extraH, &1))) |> Enum.max()
        end
      end)

    rank_y =
      Enum.reduce(1..max_rank//1, %{0 => 0}, fn r, acc ->
        Map.put(
          acc,
          r,
          Map.get(acc, r - 1) + Enum.at(rank_h, r - 1) +
            max(@gap_y, Map.get(bus_tracks, r - 1, 0) + 1)
        )
      end)

    canvas_h = Map.get(rank_y, max_rank) + Enum.at(rank_h, max_rank)
    band_end = Map.new(0..max_rank, fn r -> {r, Map.get(rank_y, r) + Enum.at(rank_h, r)} end)

    {placed, diagram_w} =
      Enum.with_index(by_rank)
      |> Enum.reduce({placed, 1}, fn {row, r}, {placed, diagram_w} ->
        Enum.reduce(row, {placed, diagram_w}, fn idx, {placed, diagram_w} ->
          w = Enum.at(sizes.boxW, idx)
          h = Enum.at(sizes.boxH, idx)
          cx = Map.get(centers, idx, 0)
          x = sat(cx, half(w))
          y = Map.get(rank_y, r) + half(Enum.at(rank_h, r) - h - Enum.at(sizes.extraH, idx))

          placed =
            Map.put(placed, idx, %{x: x, y: y, w: w, h: h, cx: cx, cy: y + half(h), rank: r})

          diagram_w = max(diagram_w, x + w)

          diagram_w =
            if Enum.at(sizes.extraH, idx) > 0 and Enum.at(sizes.selfLabelW, idx) > 0 do
              max(diagram_w, x + w + 2 + Enum.at(sizes.selfLabelW, idx))
            else
              diagram_w
            end

          {placed, diagram_w}
        end)
      end)

    content_w =
      Enum.reduce(graph.edges, diagram_w, fn e, content_w ->
        if e.from == e.to or e.label == nil do
          content_w
        else
          lw = min(Width.string_width(e.label), Labels.max_label())

          if Map.get(ranks, e.to, 0) == Map.get(ranks, e.from, 0) + 1 do
            max(content_w, Map.fetch!(placed, e.to).cx + 2 + lw)
          else
            max(content_w, diagram_w + lw + 1)
          end
        end
      end)

    {edge_lane, lane_base, canvas_w} = assign_lane_tracks(graph, ranks, placed, true, content_w)

    {%{
       canvas_w: canvas_w,
       canvas_h: canvas_h,
       band_end: band_end,
       edge_bus: edge_bus,
       lane_base: lane_base,
       edge_lane: edge_lane
     }, placed}
  end

  defp place_lr(ranks, max_rank, by_rank, sizes, graph, placed) do
    col_w =
      Enum.map(by_rank, fn row ->
        if row == [], do: 0, else: row |> Enum.map(&Enum.at(sizes.boxW, &1)) |> Enum.max()
      end)

    label_widths =
      Enum.filter(graph.edges, fn e ->
        (e.from == e.to or Map.get(ranks, e.to, 0) == Map.get(ranks, e.from, 0) + 1) and
          e.label != nil
      end)
      |> Enum.map(fn e -> min(Width.string_width(e.label), Labels.max_label()) end)

    max_label = if label_widths == [], do: 0, else: Enum.max(label_widths)
    base_gap = max(@gap_x + 1, max_label + 3)

    centers = assign_positions(by_rank, sizes.layH, 1, graph.edges, ranks)

    {edge_bus, bus_tracks} = assign_bus_tracks(graph, ranks, centers, true, max_rank)

    rank_x =
      Enum.reduce(1..max_rank//1, %{0 => 0}, fn r, acc ->
        Map.put(
          acc,
          r,
          Map.get(acc, r - 1) + Enum.at(col_w, r - 1) +
            max(base_gap, Map.get(bus_tracks, r - 1, 0) + 1)
        )
      end)

    last_row = List.last(by_rank) || []

    self_tails =
      Enum.filter(last_row, fn i ->
        Enum.at(sizes.extraH, i) > 0 and Enum.at(sizes.selfLabelW, i) > 0
      end)
      |> Enum.map(fn i -> 2 + Enum.at(sizes.selfLabelW, i) end)

    canvas_w =
      Map.get(rank_x, max_rank) + Enum.at(col_w, max_rank) +
        if self_tails == [], do: 0, else: Enum.max(self_tails)

    band_end = Map.new(0..max_rank, fn r -> {r, Map.get(rank_x, r) + Enum.at(col_w, r)} end)

    {placed, diagram_h} =
      Enum.with_index(by_rank)
      |> Enum.reduce({placed, 1}, fn {row, r}, {placed, diagram_h} ->
        x = Map.get(rank_x, r)

        Enum.reduce(row, {placed, diagram_h}, fn idx, {placed, diagram_h} ->
          w = Enum.at(sizes.boxW, idx)
          h = Enum.at(sizes.boxH, idx)
          cy = Map.get(centers, idx, 0)
          y = sat(cy, half(h + Enum.at(sizes.extraH, idx)))

          placed =
            Map.put(placed, idx, %{
              x: x,
              y: y,
              w: w,
              h: h,
              cx: x + half(w),
              cy: y + half(h),
              rank: r
            })

          {placed, max(diagram_h, y + h + Enum.at(sizes.extraH, idx))}
        end)
      end)

    {edge_lane, lane_base, canvas_h} = assign_lane_tracks(graph, ranks, placed, false, diagram_h)

    {%{
       canvas_w: canvas_w,
       canvas_h: canvas_h,
       band_end: band_end,
       edge_bus: edge_bus,
       lane_base: lane_base,
       edge_lane: edge_lane
     }, placed}
  end

  # -------------------------------------------------------------------- canvas

  @doc "Rank, place, draw and route a graph onto a fresh canvas."
  @spec layout_canvas(GrokMermaid.Graph.t(), [extra()]) :: Canvas.t() | nil
  def layout_canvas(%GrokMermaid.Graph{nodes: []}, _extras), do: nil

  def layout_canvas(graph, extras) do
    n = length(graph.nodes)

    ranks = compute_ranks(graph)
    max_rank = ranks |> Map.values() |> Enum.max(fn -> 0 end)
    ids = 0..(n - 1)

    by_rank =
      Enum.reduce(ids, Map.new(0..max_rank, &{&1, []}), fn idx, by_rank ->
        r = Map.get(ranks, idx, 0)
        Map.update!(by_rank, r, &(&1 ++ [idx]))
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    by_rank = order_ranks(by_rank, graph.edges, ranks)

    wrapped =
      Enum.map(graph.nodes, fn node ->
        Labels.wrap_label(node.label, Labels.wrap_width(), Labels.max_lines())
      end)

    widest = fn lines ->
      lines |> Enum.map(&Width.string_width/1) |> Enum.max(fn -> 1 end) |> max(1)
    end

    box_w =
      Enum.with_index(extras)
      |> Enum.map(fn {extra, i} ->
        case extra.kind do
          :frame ->
            max(
              extra.sub.w + 2,
              Width.string_width(
                Labels.fit_label(Enum.at(graph.nodes, i).label, Labels.wrap_width())
              ) + 4
            )

          :compartments ->
            widest.(Enum.flat_map(extra.sections, & &1)) + 2 * @pad + 2

          :plain ->
            widest.(Enum.at(wrapped, i)) + 2 * @pad + 2
        end
      end)

    box_h =
      Enum.with_index(extras)
      |> Enum.map(fn {extra, i} ->
        case extra.kind do
          :frame ->
            extra.sub.h + 2

          :compartments ->
            filled = Enum.count(extra.sections, &(&1 != []))

            Enum.reduce(extra.sections, 0, fn sec, acc -> acc + length(sec) end) + sat(filled, 1) +
              2

          :plain ->
            length(Enum.at(wrapped, i)) + 2
        end
      end)

    extra_h = List.duplicate(0, n)
    self_label_w = List.duplicate(0, n)

    {extra_h, self_label_w} =
      Enum.reduce(graph.edges, {extra_h, self_label_w}, fn e, {extra_h, self_label_w} ->
        if e.from != e.to do
          {extra_h, self_label_w}
        else
          extra_h = List.update_at(extra_h, e.from, fn _ -> 2 end)

          self_label_w =
            if e.label != nil do
              lw = min(Width.string_width(e.label), Labels.max_label())
              List.update_at(self_label_w, e.from, fn cur -> max(cur, lw) end)
            else
              self_label_w
            end

          {extra_h, self_label_w}
        end
      end)

    box_w =
      Enum.with_index(box_w)
      |> Enum.map(fn {w, i} -> if Enum.at(extra_h, i) > 0, do: max(w, 7), else: w end)

    sizes = %{
      boxW: box_w,
      boxH: box_h,
      layW:
        Enum.with_index(box_w, fn w, i ->
          w + if(Enum.at(self_label_w, i) > 0, do: 2 * (Enum.at(self_label_w, i) + 3), else: 0)
        end),
      layH: Enum.with_index(box_h, fn h, i -> h + Enum.at(extra_h, i) end),
      extraH: extra_h,
      selfLabelW: self_label_w
    }

    placed =
      Map.new(ids, fn i ->
        {i, %{x: 0, y: 0, w: 0, h: 0, cx: 0, cy: 0, rank: 0}}
      end)

    vertical = graph.dir in [:down, :up]

    {plan, placed} =
      if vertical do
        place_td(ranks, max_rank, by_rank, sizes, graph, placed)
      else
        place_lr(ranks, max_rank, by_rank, sizes, graph, placed)
      end

    if plan.canvas_w * plan.canvas_h > @max_canvas_cells do
      nil
    else
      canvas = Canvas.new(plan.canvas_w, plan.canvas_h)

      canvas =
        Enum.reduce(ids, canvas, fn idx, canvas ->
          node = Enum.at(graph.nodes, idx)
          extra = Enum.at(extras, idx)

          canvas =
            Canvas.set_tag(
              canvas,
              if(Map.get(node, :classes, []) == [],
                do: nil,
                else: Enum.join(Map.get(node, :classes, []), " ")
              )
            )

          canvas = Canvas.set_href(canvas, Map.get(node, :href))

          case extra.kind do
            :frame ->
              draw_frame(
                canvas,
                Map.fetch!(placed, idx),
                node.label,
                extra.sub
              )

            :compartments ->
              draw_class_box(canvas, Map.fetch!(placed, idx), extra.sections)

            :plain ->
              draw_box(
                canvas,
                Map.fetch!(placed, idx),
                Enum.at(wrapped, idx),
                node.shape
              )
          end
        end)

      canvas = Canvas.set_tag(canvas, nil)
      canvas = Canvas.set_href(canvas, nil)

      canvas =
        Enum.with_index(graph.edges)
        |> Enum.reduce(canvas, fn {edge, i}, canvas ->
          canvas = set_edge_style(canvas, edge.line)
          route_edge(canvas, edge, i, placed, ranks, plan, vertical)
        end)

      Canvas.finalize_mask(canvas)
    end
  end

  defp set_edge_style(canvas, line) do
    %{
      canvas
      | cur_style:
          if(line == :dotted,
            do: Canvas.style_dot(),
            else: if(line == :thick, do: Canvas.style_thick(), else: Canvas.style_solid())
          )
    }
  end

  defp route_edge(canvas, edge, i, placed, _ranks, plan, vertical) do
    if edge.from == edge.to do
      route_self(canvas, Map.fetch!(placed, edge.from), edge)
    else
      from = Map.fetch!(placed, edge.from)
      to = Map.fetch!(placed, edge.to)
      adjacent = to.rank == from.rank + 1
      bus = Map.get(plan.band_end, from.rank, 0) + Map.get(plan.edge_bus, i, 0)
      lane = plan.lane_base + Map.get(plan.edge_lane, i, 0)

      cond do
        vertical and adjacent -> route_forward(canvas, from, to, edge, bus)
        vertical -> route_back(canvas, from, to, edge, lane)
        adjacent -> route_forward_lr(canvas, from, to, edge, bus)
        true -> route_back_lr(canvas, from, to, edge, lane)
      end
    end
  end

  @doc "Apply the direction flip a finished canvas needs for `BT` / `RL`."
  @spec orient(Canvas.t(), GrokMermaid.Graph.t()) :: Canvas.t()
  def orient(canvas, graph) do
    cond do
      graph.dir == :up -> Canvas.flip_vertical(canvas)
      graph.dir == :left -> Canvas.flip_horizontal(canvas)
      true -> canvas
    end
  end

  @doc "Flowchart and state diagrams: plain boxes, no extra content."
  @spec layout_flowchart(GrokMermaid.Graph.t()) :: Canvas.t() | nil
  def layout_flowchart(graph) do
    extras = Enum.map(graph.nodes, fn _ -> %{kind: :plain} end)
    canvas = layout_canvas(graph, extras)
    if canvas, do: orient(canvas, graph), else: nil
  end

  # ------------------------------------------------------------------- groups

  # Subgraph layout: edges are bucketed by the scope that draws them, frames
  # are laid out recursively bottom-up, and the top scope is drawn last.
  # Ported from layout.ts `layoutGrouped` / `buildScope`.

  defp node_key(i), do: "n#{i}"
  defp group_key(g), do: "g#{g}"

  @doc "Subgraph frames nested inside each other, edges routed per scope."
  @spec layout_grouped(GrokMermaid.Graph.t()) :: Canvas.t() | nil
  def layout_grouped(graph) do
    # A node whose id matches a subgraph id stands in for that subgraph.
    proxy =
      Enum.reduce(Enum.with_index(graph.groups), %{}, fn {g, gi}, acc ->
        case Map.get(graph.index, g.id) do
          nil -> acc
          ni -> Map.put(acc, ni, gi)
        end
      end)

    group_chain = fn g ->
      g
      |> Stream.iterate(fn cur -> Enum.at(graph.groups, cur).parent end)
      |> Enum.take_while(&(&1 != nil))
      |> Enum.reverse()
    end

    endpoint = fn n ->
      case Map.get(proxy, n) do
        nil ->
          {node_key(n), group_chain.(Enum.at(graph.node_group, n))}

        gi ->
          {group_key(gi), group_chain.(Enum.at(graph.groups, gi).parent)}
      end
    end

    {scope_edges, referenced} =
      Enum.reduce(Enum.with_index(graph.edges), {%{}, MapSet.new()}, fn {e, ei},
                                                                        {scope_edges, referenced} ->
        {f_key, f_chain} = endpoint.(e.from)
        {t_key, t_chain} = endpoint.(e.to)

        k =
          Enum.reduce_while(0..(min(length(f_chain), length(t_chain)) - 1)//1, 0, fn i, k ->
            if Enum.at(f_chain, i) == Enum.at(t_chain, i) do
              {:cont, i + 1}
            else
              {:halt, k}
            end
          end)

        scope = if k == 0, do: nil, else: Enum.at(f_chain, k - 1)
        f_key = if length(f_chain) > k, do: group_key(Enum.at(f_chain, k)), else: f_key
        t_key = if length(t_chain) > k, do: group_key(Enum.at(t_chain, k)), else: t_key

        referenced =
          [f_key, t_key]
          |> Enum.filter(&String.starts_with?(&1, "g"))
          |> Enum.reduce(referenced, fn "g" <> rest, acc ->
            MapSet.put(acc, String.to_integer(rest))
          end)

        {Map.update(scope_edges, scope, [{f_key, t_key, ei}], &(&1 ++ [{f_key, t_key, ei}])),
         referenced}
      end)

    # Nodes that belong directly to a scope, skipping proxies.
    direct_nodes =
      Enum.reduce(Enum.with_index(graph.node_group), %{}, fn {g, ni}, acc ->
        if Map.has_key?(proxy, ni) do
          acc
        else
          Map.update(acc, g, [ni], &(&1 ++ [ni]))
        end
      end)

    # Drop empty subgraphs, but keep any that an edge attaches to.
    keep =
      Enum.reduce((length(graph.groups) - 1)..0//-1, MapSet.new(), fn gi, keep ->
        has_nodes = Map.get(direct_nodes, gi, []) != []

        has_children =
          graph.groups
          |> Enum.with_index()
          |> Enum.any?(fn {g, gidx} -> g.parent == gi and MapSet.member?(keep, gidx) end)

        if has_nodes or has_children or MapSet.member?(referenced, gi) do
          MapSet.put(keep, gi)
        else
          keep
        end
      end)

    case build_scope(graph, nil, scope_edges, direct_nodes, keep) do
      nil -> nil
      canvas -> orient(canvas, graph)
    end
  end

  defp build_scope(%GrokMermaid.Graph{} = graph, scope, scope_edges, direct_nodes, keep) do
    items =
      Enum.map(Map.get(direct_nodes, scope, []), &node_key/1) ++
        (Enum.with_index(graph.groups)
         |> Enum.filter(fn {g, gi} -> g.parent == scope and MapSet.member?(keep, gi) end)
         |> Enum.map(fn {_, gi} -> group_key(gi) end))

    if items == [] do
      Canvas.new(1, 1)
    else
      index_of =
        Enum.with_index(items)
        |> Map.new(fn {item, i} -> {item, i} end)

      {nodes, extras} =
        Enum.reduce(items, {[], []}, fn item, {nodes, extras} ->
          i = String.to_integer(String.slice(item, 1..-1//1))

          if String.starts_with?(item, "n") do
            node = Enum.at(graph.nodes, i)

            {nodes ++
               [
                 %{
                   label: node.label,
                   shape: node.shape,
                   classes: Map.get(node, :classes, []),
                   href: Map.get(node, :href)
                 }
               ], extras ++ [%{kind: :plain}]}
          else
            case build_scope(graph, i, scope_edges, direct_nodes, keep) do
              nil ->
                {nodes, extras}

              sub ->
                {nodes ++
                   [
                     %{
                       label: Enum.at(graph.groups, i).label,
                       shape: :rect,
                       classes: [],
                       href: nil
                     }
                   ], extras ++ [%{kind: :frame, sub: sub}]}
            end
          end
        end)

      if length(nodes) != length(extras) do
        nil
      else
        edges =
          Enum.reduce(Map.get(scope_edges, scope, []), [], fn {f, t, ei}, edges ->
            case {Map.get(index_of, f), Map.get(index_of, t)} do
              {nil, _} ->
                edges

              {_, nil} ->
                edges

              {fi, ti} ->
                e = Enum.at(graph.edges, ei)

                edges ++
                  [
                    %{
                      from: fi,
                      to: ti,
                      label: e.label,
                      head_to: e.head_to,
                      head_from: e.head_from,
                      line: e.line
                    }
                  ]
            end
          end)

        synth = %GrokMermaid.Graph{graph | nodes: nodes, edges: edges}
        layout_canvas(synth, extras)
      end
    end
  end

  @doc "Class and ER diagrams: boxes divided into title / attribute / method rows."
  @spec layout_class(GrokMermaid.Graph.t(), [GrokMermaid.Graph.class_info()]) :: Canvas.t() | nil
  def layout_class(graph, infos) do
    extras =
      Enum.with_index(graph.nodes)
      |> Enum.map(fn {node, i} ->
        info = Enum.at(infos, i)

        title =
          if info.annotation != nil do
            ["«#{info.annotation}»"]
          else
            []
          end

        %{
          kind: :compartments,
          sections: [title ++ [Labels.display_generics(node.label)], info.attrs, info.methods]
        }
      end)

    canvas = layout_canvas(graph, extras)
    if canvas, do: orient(canvas, graph), else: nil
  end

  # ------------------------------------------------------------------- drawing

  @doc "Draw a box with its label lines and shape."
  @spec draw_box(Canvas.t(), placed(), [String.t()], GrokMermaid.Graph.shape()) :: Canvas.t()
  def draw_box(canvas, p, lines, shape) do
    x = p.x
    y = p.y
    w = p.w
    h = p.h
    right = x + w - 1
    bottom = y + h - 1

    # A diamond is a double-line box — the terminal's nod to `A{...}`.
    {tl, tr, bl, br} =
      case shape do
        :diamond -> {"╔", "╗", "╚", "╝"}
        :round -> {"╭", "╮", "╰", "╯"}
        _ -> {"┌", "┐", "└", "┘"}
      end

    canvas =
      canvas
      |> Canvas.set(x, y, tl, :border)
      |> Canvas.set(right, y, tr, :border)
      |> Canvas.set(x, bottom, bl, :border)
      |> Canvas.set(right, bottom, br, :border)

    canvas =
      if shape == :diamond do
        # Double lines carry no direction bits; edges tee into them through
        # the mixed junctions (`╤` `╧` `╟` `╢`) that `finalize_mask` resolves.
        canvas =
          Enum.reduce((x + 1)..(right - 1)//1, canvas, fn cx, canvas ->
            canvas
            |> Canvas.set(cx, y, "═", :border)
            |> Canvas.set(cx, bottom, "═", :border)
          end)

        Enum.reduce((y + 1)..(bottom - 1)//1, canvas, fn cy, canvas ->
          canvas
          |> Canvas.set(x, cy, "║", :border)
          |> Canvas.set(right, cy, "║", :border)
        end)
      else
        # The perimeter is drawn as bits so edges can tee into it, but it is
        # the box outline, so it claims `border` rather than `edge`.
        canvas =
          Enum.reduce((x + 1)..(right - 1)//1, canvas, fn cx, canvas ->
            canvas
            |> Canvas.add_bits(cx, y, 12, :border)
            |> Canvas.add_bits(cx, bottom, 12, :border)
          end)

        Enum.reduce((y + 1)..(bottom - 1)//1, canvas, fn cy, canvas ->
          canvas
          |> Canvas.add_bits(x, cy, 3, :border)
          |> Canvas.add_bits(right, cy, 3, :border)
        end)
      end

    canvas = occupy_box(canvas, x, y, right, bottom)
    inner = max(1, sat(w, 2 * @pad + 2))

    Enum.with_index(lines)
    |> Enum.reduce(canvas, fn {line, li}, canvas ->
      text = Labels.fit_label(line, inner)
      text_x = x + 1 + @pad + half(sat(inner, Width.string_width(text)))
      Canvas.draw_text(canvas, text, text_x, y + 1 + li, :text)
    end)
  end

  defp occupy_box(canvas, x, y, right, bottom) do
    Enum.reduce(y..bottom, canvas, fn cy, canvas ->
      Enum.reduce(x..right, canvas, fn cx, canvas -> Canvas.occupy(canvas, cx, cy) end)
    end)
  end

  defp draw_class_box(canvas, p, sections) do
    canvas = draw_box(canvas, p, [], :rect)
    inner = max(1, sat(p.w, 2 * @pad + 2))
    {canvas, _} = draw_sections(canvas, p, sections, inner, p.y + 1, true)
    canvas
  end

  defp draw_sections(canvas, _p, [], _inner, row, _first), do: {canvas, row}

  defp draw_sections(canvas, p, [section | rest], inner, row, first) do
    if section == [] do
      draw_sections(canvas, p, rest, inner, row, first)
    else
      {canvas, row} =
        if first do
          {canvas, row}
        else
          canvas = Canvas.set(canvas, p.x, row, "├", :border)

          canvas =
            Enum.reduce((p.x + 1)..(p.x + p.w - 2)//1, canvas, fn x, canvas ->
              Canvas.set(canvas, x, row, "─", :border)
            end)

          canvas = Canvas.set(canvas, p.x + p.w - 1, row, "┤", :border)
          {canvas, row + 1}
        end

      {canvas, row} =
        Enum.reduce(section, {canvas, row}, fn line, {canvas, row} ->
          text = Labels.fit_label(line, inner)

          tx =
            if first,
              do: p.x + 1 + @pad + half(sat(inner, Width.string_width(text))),
              else: p.x + 1 + @pad

          {Canvas.draw_text_over_edges(canvas, text, tx, row, :text), row + 1}
        end)

      draw_sections(canvas, p, rest, inner, row, false)
    end
  end

  defp draw_frame(canvas, p, title, sub) do
    canvas = draw_box(canvas, p, [], :rect)

    canvas =
      if title != "" do
        t = Labels.fit_label(title, sat(p.w, 4))
        Canvas.draw_text_over_edges(canvas, " " <> t <> " ", p.x + 1, p.y, :text)
      else
        canvas
      end

    Canvas.blit(canvas, sub, p.x + 1 + half(p.w - 2 - sub.w), p.y + 1 + half(p.h - 2 - sub.h))
  end

  # ------------------------------------------------------------------- routing

  defp head_glyph(head, arrow) do
    case head do
      :circle -> "o"
      :cross -> "×"
      :diamond_fill -> "◆"
      :diamond_open -> "◇"
      :triangle -> Map.get(%{"▼" => "▽", "▲" => "△", "◄" => "◁", "▶" => "▷"}, arrow, arrow)
      _ -> arrow
    end
  end

  # Adjacent ranks, top-down: drop, jog along the bus row, drop into the head.
  defp route_forward(canvas, from, to, edge, bus) do
    tx = to.cx
    bx = if abs(from.cx - tx) <= 1, do: tx, else: from.cx
    by = from.y + from.h - 1
    head_row = to.y - 1

    canvas =
      canvas
      |> Canvas.junction(bx, by, 2)
      |> Canvas.seg_v(bx, by, bus)

    canvas =
      if bx == tx do
        Canvas.seg_v(canvas, bx, bus, head_row)
      else
        canvas
        |> Canvas.seg_h(bus, bx, tx)
        |> Canvas.seg_v(tx, bus, head_row)
      end

    canvas =
      if edge_head_none(edge.head_to) do
        Canvas.add_bits(canvas, tx, head_row, 1)
      else
        Canvas.set(canvas, tx, head_row, head_glyph(edge.head_to, "▼"), :edge)
      end

    canvas =
      if edge_head_none(edge.head_from),
        do: canvas,
        else: Canvas.set(canvas, bx, by, head_glyph(edge.head_from, "▲"), :edge)

    if edge.label != nil, do: place_label(canvas, edge.label, head_row, tx + 1), else: canvas
  end

  # A self-edge: a stub loop hanging below the box.
  defp route_self(canvas, p, edge) do
    bottom = p.y + p.h - 1
    exit_x = p.cx + 1
    ret_x = p.x + p.w - 2

    if ret_x <= exit_x or bottom + 2 >= canvas.h do
      canvas
    else
      {v, h, bl, br} =
        case edge.line do
          :dotted -> {"╎", "╌", "╰", "╯"}
          :thick -> {"┃", "━", "┗", "┛"}
          _ -> {"│", "─", "╰", "╯"}
        end

      canvas =
        canvas
        |> Canvas.junction(exit_x, bottom, 2)
        |> Canvas.set(exit_x, bottom + 1, v, :edge)
        |> Canvas.set(exit_x, bottom + 2, bl, :edge)

      canvas =
        Enum.reduce((exit_x + 1)..(ret_x - 1)//1, canvas, fn x, canvas ->
          Canvas.set(canvas, x, bottom + 2, h, :edge)
        end)

      canvas =
        canvas
        |> Canvas.set(ret_x, bottom + 2, br, :edge)
        |> Canvas.set(ret_x, bottom + 1, head_glyph(edge.head_to, "▲"), :edge)

      if edge.label != nil,
        do: place_label(canvas, edge.label, bottom + 1, p.x + p.w + 1),
        else: canvas
    end
  end

  # Skip or back edge, top-down: out the right side, up a lane, back in.
  defp route_back(canvas, from, to, edge, lane_x) do
    sx = from.x + from.w - 1
    sy = from.cy
    tx = to.x + to.w - 1
    tyc = to.cy

    canvas =
      canvas
      |> Canvas.junction(sx, sy, 8)
      |> Canvas.seg_h(sy, sx, lane_x)
      |> Canvas.seg_v(lane_x, sy, tyc)
      |> Canvas.seg_h(tyc, tx + 1, lane_x)

    canvas =
      if edge_head_none(edge.head_to) do
        Canvas.add_bits(canvas, tx + 1, tyc, 8)
      else
        Canvas.set(canvas, tx + 1, tyc, head_glyph(edge.head_to, "◄"), :edge)
      end

    canvas =
      if edge_head_none(edge.head_from),
        do: canvas,
        else: Canvas.set(canvas, sx, sy, head_glyph(edge.head_from, "◄"), :edge)

    if edge.label != nil do
      place_label(
        canvas,
        edge.label,
        sat(tyc, 1),
        sat(lane_x, Width.string_width(edge.label) + 1)
      )
    else
      canvas
    end
  end

  # Adjacent ranks, left-to-right: out the right side, jog on the bus column.
  defp route_forward_lr(canvas, from, to, edge, bus) do
    rx = from.x + from.w - 1
    ry = from.cy
    ly = to.cy
    head_col = to.x - 1

    canvas =
      canvas
      |> Canvas.junction(rx, ry, 8)
      |> Canvas.seg_h(ry, rx, bus)

    canvas =
      if ry == ly do
        Canvas.seg_h(canvas, ry, bus, head_col)
      else
        canvas
        |> Canvas.seg_v(bus, ry, ly)
        |> Canvas.seg_h(ly, bus, head_col)
      end

    canvas =
      if edge_head_none(edge.head_to) do
        Canvas.add_bits(canvas, head_col, ly, 8)
      else
        Canvas.set(canvas, head_col, ly, head_glyph(edge.head_to, "▶"), :edge)
      end

    canvas =
      if edge_head_none(edge.head_from),
        do: canvas,
        else: Canvas.set(canvas, rx, ry, head_glyph(edge.head_from, "◄"), :edge)

    if edge.label != nil, do: place_label(canvas, edge.label, sat(ly, 1), bus + 1), else: canvas
  end

  # Skip or back edge, left-to-right: down out the bottom, along a lane, back up.
  defp route_back_lr(canvas, from, to, edge, lane_y) do
    sx = from.cx
    sy = from.y + from.h - 1
    tx = to.cx
    ty = to.y + to.h - 1

    canvas =
      canvas
      |> Canvas.junction(sx, sy, 2)
      |> Canvas.seg_v(sx, sy, lane_y)
      |> Canvas.seg_h(lane_y, sx, tx)
      |> Canvas.seg_v(tx, lane_y, ty + 1)

    canvas =
      if edge_head_none(edge.head_to) do
        Canvas.add_bits(canvas, tx, ty + 1, 2)
      else
        Canvas.set(canvas, tx, ty + 1, head_glyph(edge.head_to, "▲"), :edge)
      end

    canvas =
      if edge_head_none(edge.head_from),
        do: canvas,
        else: Canvas.set(canvas, sx, sy, head_glyph(edge.head_from, "▲"), :edge)

    if edge.label != nil,
      do: place_label(canvas, edge.label, sat(lane_y, 1), half(sx + tx)),
      else: canvas
  end

  defp edge_head_none(:none), do: true
  defp edge_head_none(_), do: false

  # Write an edge label, stopping at the first cell already occupied.
  defp place_label(canvas, label, row, start_x) do
    if row >= canvas.h do
      canvas
    else
      text = Labels.fit_label(label, Labels.max_label())
      {canvas, _} = paint_label(canvas, Width.measured(text), row, start_x)
      canvas
    end
  end

  defp paint_label(canvas, [], _row, _x), do: {canvas, nil}

  defp paint_label(canvas, [{c, cw} | rest], row, x) do
    if cw == 0 do
      paint_label(canvas, rest, row, x)
    else
      if x + cw > canvas.w do
        {canvas, nil}
      else
        blocked =
          Enum.any?(0..(cw - 1), fn k ->
            i = row * canvas.w + (x + k)

            Map.get(canvas.ch, i, " ") != " " or Map.get(canvas.mask, i, 0) != 0 or
              Map.get(canvas.occupied, i, 0) != 0
          end)

        if blocked do
          {canvas, nil}
        else
          canvas = Canvas.set(canvas, x, row, c, :edge_label)

          canvas =
            Enum.reduce(1..(cw - 1)//1, canvas, fn k, canvas ->
              Canvas.set(canvas, x + k, row, <<0>>, :edge_label)
            end)

          paint_label(canvas, rest, row, x + cw)
        end
      end
    end
  end
end
