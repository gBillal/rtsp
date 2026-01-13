# RTSP

[![Hex.pm](https://img.shields.io/hexpm/v/rtsp.svg)](https://hex.pm/packages/rtsp)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/rtsp)

Simplify connecting to RTSP servers.

## Usage

Start the client, connect and start receiving media

```elixir
{:ok, session} = RTSP.start_link(stream_uri: "rtsp://localhost:554/stream", allowed_media_types: [:video])
{:ok, tracks} = RTSP.connect(session)
:ok = RTSP.play(session)
```

The current process will receive media stream:
```elixir
{:rtsp, pid_or_name, {control_path, {sample, rtp_timestamp, key_frame?, timestamp}}}
```

## Installation

The package can be installed by adding `rtsp` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rtsp, "~> 0.7.0"}
  ]
end
```

## Supported Media Types

The following media types are depayloaded and parsed:
- H264
- H265
- AV1
- AAC (lbr and hbr)
- G711 (a-law and u-law)

A payloader is available for the following media types:
- H264
- H265
- AAC (lbr and hbr)
- G711 (a-law and u-law)
