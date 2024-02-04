defmodule Nostr.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://git.sr.ht/jurraca/nostr"

  def project do
    [
      app: :nostr,
      version: @version,
      description: "An Elixir client for Nostr",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "Nostr",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def package do
    [
      maintainers: ["jurraca"],
      licenses: ["MIT"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [ "README.md" ],
      assets: "/guides/assets",
      source_ref: @version,
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Nostr.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.29.1", only: [:dev], runtime: false},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:hammox, "~> 0.7", only: :test},
      {:mint_web_socket, "~> 1.0"},
      {:nostrlib, git: "https://git.sr.ht/~jurraca/nostrlib"}
    ]
  end
end
