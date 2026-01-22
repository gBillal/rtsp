# RTSP

[![Hex.pm](https://img.shields.io/hexpm/v/rtsp.svg)](https://hex.pm/packages/rtsp)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/rtsp)

RTSP built on top of [Membrane RTSP]() to simplify streaming and serving media using `RTSP` protocol.

## Client

The client depayload and parse received rtp packets. For list of supported media types: see [supported media types](#supported-media-types)

### Usage

Start the client, connect and start receiving media

```elixir
{:ok, session} = RTSP.start_link(stream_uri: "rtsp://localhost:554/stream", allowed_media_types: [:video])
{:ok, tracks} = RTSP.connect(session)
:ok = RTSP.play(session)
```

The current process will receive media stream:
```elixir
{:rtsp, pid_or_name, {control_path, {sample, rtp_timestamp, key_frame?, timestamp_ms}}}
```

## Server
There's two implementation for server side:

### File Server
A simple rtsp server that serves local files.

```elixir
{:ok, server} = RTSP.FileServer.start_link(port: 8554, files: [%{path: "/test", location: "/tmp/test.mp4"}])
```

You can play the stream using vlc or ffplay:
```bash
ffplay -i rtsp://localhost:8554/test
```

### Server
The generic server implementation `RTSP.Server` only support publishing (streaming is planned).

## Installation

The package can be installed by adding `rtsp` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rtsp, "~> 0.8.0"}
  ]
end
```

## Supported Media Types

| Codec | Payloader | Depayloader |
|-------|-----------|-------------|
| [H264](https://datatracker.ietf.org/doc/html/rfc6184)  |  ✔️        |  ✔️          |
| [H265](https://datatracker.ietf.org/doc/html/rfc7798)  |  ✔️        |  ✔️          |
| [AV1](https://aomediacodec.github.io/av1-rtp-spec/v1.0.0.html)   |  ✔️        |  ✔️          |
| VP8   |           |             |
| VP9   |           |             |
| MJPEG |           |             |
| AAC   |  ✔️        |  ✔️          |
| G711  |  ✔️        |  ✔️          |
| [Opus](https://datatracker.ietf.org/doc/html/rfc7587)  |  ✔️        |  ✔️          |
| Vorbis|           |             |
| AC-3  |           |             |

