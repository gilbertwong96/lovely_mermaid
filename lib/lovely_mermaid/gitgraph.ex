defmodule LovelyMermaid.GitGraph do
  @moduledoc """
  `gitGraph`: commit lanes, drawn the way `git log --graph` draws them —
  newest commit on top, one column per branch, connector rows where
  history splits, ported from grok-mermaid's gitgraph.ts. Lenient: an
  unreadable statement is dropped and recorded in `warnings`.

  Connector rows go through the canvas direction bits, so a merge reaching
  across an active lane crosses it with a `┼` instead of erasing it.
  """

  alias LovelyMermaid.{Canvas, Graph, Labels, Parse, Width}

  defmodule Commit do
    @moduledoc false
    defstruct [:lane, :id, :tag, :merge_from]

    @type t :: %__MODULE__{
            lane: non_neg_integer(),
            id: String.t(),
            tag: String.t() | nil,
            merge_from: non_neg_integer() | nil
          }
  end

  @doc "Render a `gitGraph` source to a canvas, or `nil` when nothing parses."
  @spec render(String.t()) :: {Canvas.t(), map(), [String.t()]} | nil
  def render(src) do
    case parse(src) do
      {:ok, branches, commits, fork_at, warnings} ->
        lane_count = tuple_size(branches)
        commits_t = List.to_tuple(commits)

        # The newest commit of each lane wears the branch name.
        head_of = Map.new(Enum.with_index(commits), fn {c, i} -> {c.lane, i} end)

        rows = build_rows(commits, branches, fork_at)

        lane_x = fn lane -> lane * 2 end
        graph_w = lane_count * 2

        labels =
          Enum.map(rows, fn
            %{kind: :commit, at: at} ->
              c = elem(commits_t, at)

              parts =
                if c.id == "" do
                  []
                else
                  [{c.id, :text}]
                end

              parts =
                if Map.get(head_of, c.lane) == at,
                  do: [{"(#{elem(branches, c.lane)})", :edge_label} | parts],
                  else: parts

              parts = if c.tag != nil, do: [{"[#{c.tag}]", :edge_label} | parts], else: parts

              parts =
                if c.merge_from != nil,
                  do: [{"⇐ #{elem(branches, c.merge_from)}", :edge_label} | parts],
                  else: parts

              Enum.reverse(parts)

            _ ->
              nil
          end)

        labels_t = List.to_tuple(labels)

        width =
          graph_w +
            max(
              1,
              labels
              |> Enum.map(fn parts ->
                if parts == nil do
                  0
                else
                  Enum.reduce(parts, 0, fn {t, _role}, w -> w + Width.string_width(t) + 1 end) - 1
                end
              end)
              |> Enum.max(fn -> 0 end)
            )

        canvas = Canvas.new(width, length(rows))

        {canvas, _live} =
          Enum.reduce(Stream.with_index(rows), {canvas, MapSet.new()}, fn {row, y},
                                                                          {canvas, live} ->
            if row.kind == :commit do
              c = elem(commits_t, row.at)
              live = MapSet.put(live, c.lane)

              canvas =
                Enum.reduce(live, canvas, fn lane, canvas ->
                  if lane != c.lane do
                    Canvas.add_bits(
                      canvas,
                      lane_x.(lane),
                      y,
                      Bitwise.bor(Canvas.bit_u(), Canvas.bit_d())
                    )
                  else
                    canvas
                  end
                end)

              canvas = Canvas.set(canvas, lane_x.(c.lane), y, "●", :edge)

              {canvas, _x} =
                Enum.reduce(at(labels_t, y) || [], {canvas, graph_w}, fn {text, role},
                                                                         {canvas, x} ->
                  canvas = Canvas.draw_text(canvas, text, x, y, role)
                  {canvas, x + Width.string_width(text) + 1}
                end)

              {canvas, live}
            else
              parent = row.parent
              lane = row.lane
              rejoins = row.kind == :open and MapSet.member?(live, lane)
              live = if row.kind == :open, do: MapSet.put(live, lane), else: live

              canvas =
                Enum.reduce(live, canvas, fn l, canvas ->
                  if l != parent and l != lane do
                    Canvas.add_bits(
                      canvas,
                      lane_x.(l),
                      y,
                      Bitwise.bor(Canvas.bit_u(), Canvas.bit_d())
                    )
                  else
                    canvas
                  end
                end)

              canvas =
                if row.kind == :open do
                  Canvas.add_bits(
                    canvas,
                    lane_x.(parent),
                    y,
                    Bitwise.bor(Canvas.bit_u(), Canvas.bit_d())
                  )
                else
                  Canvas.add_bits(
                    canvas,
                    lane_x.(parent),
                    y,
                    Bitwise.bor(
                      Canvas.bit_d(),
                      if(MapSet.member?(live, parent), do: Canvas.bit_u(), else: 0)
                    )
                  )
                end

              live = MapSet.put(live, parent)
              canvas = Canvas.seg_h(canvas, y, lane_x.(parent), lane_x.(lane))

              canvas =
                Canvas.add_bits(
                  canvas,
                  lane_x.(lane),
                  y,
                  Bitwise.bor(
                    if(row.kind == :open, do: Canvas.bit_d(), else: Canvas.bit_u()),
                    if(rejoins, do: Canvas.bit_u(), else: 0)
                  )
                )

              live = if row.kind == :close, do: MapSet.delete(live, lane), else: live
              {canvas, live}
            end
          end)

        canvas = Canvas.finalize_mask(canvas)
        {canvas, %{}, warnings}

      :error ->
        nil
    end
  end

  @doc false
  @spec parse(String.t()) ::
          {:ok, tuple(), [Commit.t()], tuple(), [String.t()]} | :error
  def parse(src) do
    statements = Parse.statements_of(src)
    kind = Parse.header_kind(statements)

    if kind == nil or kind not in ["gitgraph", "gitgraph:"] do
      :error
    else
      branches = {"main"}
      fork_at = {nil}
      commits = []
      heads = {nil}
      cur = 0
      auto = 0

      {branches, fork_at, commits, _heads, _cur, _auto, warnings, truncated} =
        Enum.reduce(
          Enum.drop(statements, 1),
          {branches, fork_at, commits, heads, cur, auto, [], false},
          fn st, {branches, fork_at, commits, heads, cur, auto, warnings, truncated} ->
            if truncated or length(commits) >= Graph.max_edges() do
              {branches, fork_at, commits, heads, cur, auto, warnings, true}
            else
              first =
                st
                |> words()
                |> List.first()
                |> then(&if &1, do: Labels.ascii_lower(&1), else: "")

              rest = st |> words() |> Enum.drop(1) |> Enum.join(" ")

              case first do
                "commit" ->
                  attrs = commit_attrs(rest)
                  heads = put_elem(heads, cur, length(commits))

                  commits = [
                    %Commit{
                      lane: cur,
                      id: attrs.id || "c#{auto}",
                      tag: attrs.tag,
                      merge_from: nil
                    }
                    | commits
                  ]

                  auto = auto + if(attrs.id == nil, do: 1, else: 0)
                  {branches, fork_at, commits, heads, cur, auto, warnings, false}

                "branch" ->
                  {name, _after} = name_token(rest)
                  fork = elem(heads, cur) || elem(fork_at, cur)

                  if name == nil or name in Tuple.to_list(branches) or fork == nil do
                    {branches, fork_at, commits, heads, cur, auto,
                     ["dropped, unreadable statement: \"#{st}\"" | warnings], false}
                  else
                    branches = :erlang.append_element(branches, name)
                    fork_at = :erlang.append_element(fork_at, fork)
                    heads = :erlang.append_element(heads, nil)

                    {branches, fork_at, commits, heads, tuple_size(branches) - 1, auto, warnings,
                     false}
                  end

                first when first in ["checkout", "switch"] ->
                  {name, _after} = name_token(rest)
                  lane = branches |> Tuple.to_list() |> Enum.find_index(&(&1 == name))

                  if lane == nil do
                    {branches, fork_at, commits, heads, cur, auto,
                     ["dropped, unreadable statement: \"#{st}\"" | warnings], false}
                  else
                    {branches, fork_at, commits, heads, lane, auto, warnings, false}
                  end

                "merge" ->
                  {name, rest_after} = name_token(rest)
                  lane = branches |> Tuple.to_list() |> Enum.find_index(&(&1 == name))

                  if lane == nil or lane == cur do
                    {branches, fork_at, commits, heads, cur, auto,
                     ["dropped, unreadable statement: \"#{st}\"" | warnings], false}
                  else
                    attrs = commit_attrs(rest_after)
                    heads = put_elem(heads, cur, length(commits))

                    commits =
                      [
                        %Commit{lane: cur, id: attrs.id || "", tag: attrs.tag, merge_from: lane}
                        | commits
                      ]

                    {branches, fork_at, commits, heads, cur, auto, warnings, false}
                  end

                "cherry-pick" ->
                  attrs = commit_attrs(rest)
                  heads = put_elem(heads, cur, length(commits))
                  id = if attrs.id == nil, do: "c#{auto}", else: "⟲ #{attrs.id}"

                  commits = [
                    %Commit{lane: cur, id: id, tag: attrs.tag, merge_from: nil} | commits
                  ]

                  auto = auto + if(attrs.id == nil, do: 1, else: 0)
                  {branches, fork_at, commits, heads, cur, auto, warnings, false}

                _ ->
                  {branches, fork_at, commits, heads, cur, auto,
                   ["dropped, unreadable statement: \"#{st}\"" | warnings], false}
              end
            end
          end
        )

      warnings =
        if truncated,
          do: ["diagram truncated: commit cap (#{Graph.max_edges()}) reached" | warnings],
          else: warnings

      if commits == [] do
        :error
      else
        {:ok, branches, Enum.reverse(commits), fork_at, Enum.reverse(warnings)}
      end
    end
  end

  # Build the row plan: commit rows interleaved with connector rows.
  # `open` hangs a merged lane off its merge commit, `close` returns a
  # forked lane to its parent at its fork point. Lanes never used (a branch
  # with no commits that nothing merged) simply never open.
  defp at(t, i) when is_tuple(t) and i >= 0 and i < tuple_size(t), do: elem(t, i)
  defp at(_t, _i), do: nil

  defp build_rows(commits, branches, fork_at) do
    commits_t = List.to_tuple(commits)

    used =
      branches
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {_b, lane} ->
        Enum.any?(commits, fn c -> c.lane == lane or c.merge_from == lane end) or lane == 0
      end)
      |> List.to_tuple()

    {rows, _} =
      Enum.reduce((length(commits) - 1)..0//-1, {[], used}, fn i, {rows, used} ->
        c = elem(commits_t, i)
        rows = [%{kind: :commit, at: i} | rows]

        rows =
          if c.merge_from != nil do
            [%{kind: :open, parent: c.lane, lane: c.merge_from} | rows]
          else
            rows
          end

        # Close outer lanes first so an inner close still sees them as columns.
        {rows, _used} =
          Enum.reduce((tuple_size(branches) - 1)..1//-1, {rows, used}, fn lane, {rows, used} ->
            if elem(fork_at, lane) == i - 1 and elem(used, lane) do
              {[%{kind: :close, parent: elem(commits_t, i - 1).lane, lane: lane} | rows], used}
            else
              {rows, used}
            end
          end)

        {rows, used}
      end)

    Enum.reverse(rows)
  end

  @doc false
  @spec name_token(String.t()) :: {String.t() | nil, String.t()}
  def name_token(rest) do
    if String.starts_with?(rest, "\"") do
      case String.split(rest, "\"", parts: 3) do
        ["", name, rest_after] -> {name, rest_after}
        _ -> {rest |> words() |> List.first(), rest}
      end
    else
      w = rest |> words() |> List.first()

      if w == nil do
        {nil, rest}
      else
        {w, String.replace_prefix(rest, w, "")}
      end
    end
  end

  @doc false
  @spec commit_attrs(String.t()) :: %{id: String.t() | nil, tag: String.t() | nil}
  def commit_attrs(rest) do
    regex = ~r/(id|tag)\s*:\s*"([^"]*)"/i

    {id, tag} =
      Regex.scan(regex, rest)
      |> Enum.reduce({nil, nil}, fn [_, key, value], {id, tag} ->
        value = Labels.fit_label(Labels.clean_label(value), Labels.max_label())

        case String.downcase(key) do
          "id" -> {value, tag}
          "tag" -> {id, value}
        end
      end)

    %{id: id, tag: tag}
  end

  defp words(s), do: String.split(s, ~r/\s+/, trim: true)
end
