defmodule RTSP.MixProject do
  use Mix.Project

  @version "0.1.0"
  @github_url "https://github.com/gBillal/rtsp"

  def project do
    [
      app: :rtsp,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # hex
      description: "Simplify connecting to RTSP servers",
      package: package(),

      # docs
      name: "RTSP",
      source_url: @github_url,
      docs: docs()
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

  defp package do
    [
      maintainers: ["Billal Ghilas"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "LICENSE"
      ],
      nest_modules_by_prefix: [
        RTSP.RTP.Encoder,
        RTSP.RTP.Decoder
      ],
      groups_for_modules: [
        "RTP Encoders": [
          ~r/RTSP\.RTP\.Encoder($|\.)/
        ],
        "RTP Decoders": [
          ~r/RTSP\.RTP\.Decoder($|\.)/
        ],
        "RTP Extensions": [
          RTSP.RTP.OnvifReplayExtension
        ]
      ],
      formatters: ["html"],
      source_ref: "v#{@version}"
    ]
  end
end
