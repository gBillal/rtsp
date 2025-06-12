defmodule RTSP.MixProject do
  use Mix.Project

  def project do
    [
      app: :rtsp,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_sdp, "~> 1.0"},
      {:ex_rtp, "~> 0.4.0"},
      {:ex_rtcp, "~> 0.4.0"},
      {:membrane_rtsp, "~> 0.10.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
