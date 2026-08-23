defmodule LovelyMermaid.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/gilbertwong96/lovely_mermaid"

  def project do
    [
      app: :lovely_mermaid,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Quality gates
      dialyzer: [plt_add_apps: [:mix]],

      # Package
      description: "Render Mermaid diagrams as Unicode box-drawing art for terminals",
      package: package(),

      # Documentation
      name: "LovelyMermaid",
      source_url: @source_url,
      homepage_url: @source_url,
      source_ref: "v#{@version}",
      docs: [
        main: "LovelyMermaid",
        source_url: @source_url,
        source_ref: "v#{@version}"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      ci: [
        "cmd mix compile --all-warnings --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "xref graph --label compile-connected --fail-above 5",
        "dialyzer",
        "ex_dna",
        "reach.check --dead-code --smells",
        "cmd mix test"
      ]
    ]
  end

  defp package do
    [
      name: "lovely_mermaid",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Original (lovely-mermaid, npm)" => "https://github.com/xl0/lovely-mermaid"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
