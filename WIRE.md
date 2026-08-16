# The wire, and what this client does with it

Moved out of `README.md` when the forty-line rule went in. The README says what this project
is; this page says how it talks and why each choice is the one it is.

## The wire

| | |
| --- | --- |
| transport | `WebTransportPeer`, the engine's `modules/http3` over picoquic |
| state | QUIC datagrams, unreliable on purpose |
| payload | back-to-back 100-byte `XRGridEntityPacket` records, no framing |
| count | `len / 100` |
| rate | 20 Hz in, 20 Hz out |

State is unreliable because a snapshot that arrives late is worse than one that never arrives:
the next tick supersedes it in 50 ms, and retransmitting would deliver a stale pose behind a
fresh one. Anything that must not be lost opens a stream instead.

A slice is whole records by construction, so a datagram whose length is not a multiple of 100
is malformed rather than short, and this drops it. Guessing which end to trim would put a
fabricated entity in the world.

`XRGridEntityPacket.decode` does the decoding and returns metres. No file in this project knows
a field offset, and none should learn one — the layout is proved in `contract-entity-packet`
and emitted from there.

## What a player is

Three entities: a head and two hands, driven by tracking. That is the article's own avatar and
the shape the service publishes — `class_owner` carries `(class << 24) | owner`, `sub_index`
says which of the three. There is no torso between them because nothing on the wire describes
one, and inventing one here would be this client guessing at a pose it was never sent.

Your own three come back from the service like everybody else's, and are not drawn: they would
be a second head inside this one's camera.

## Interpolation, not prediction

The service publishes at 20 Hz and a headset draws at 72 or 90. The client holds the last two
snapshots and interpolates between them, clamped at the newer one.

It is clamped rather than extrapolated deliberately. Running ahead of the newest state you hold
is prediction, and prediction belongs to the service that owns authority — see
`interactor-physics`, where the rollback loop is going. A renderer that guessed would be a
second opinion about where a cube is, which is the thing the whole design refuses.

## Driving it from outside

`addons/vsekai_godot_mcp` is vendored and both halves are on: the editor plugin on 8788, and
`MCPRuntime` autoloaded into the running game on 8789. Two ports, because pressing play in an
open editor is the ordinary case and one port meant the game lost the bind while a client went
on questioning the editor. `--mcp-port=` or `GODOT_MCP_PORT` moves the runtime one.

Ask the running game, not the editor, when the question is what arrived. A node's real transform
is the difference between "the packet decoded" and "the cube is where the service put it".

## Two things that are not wired yet

- **The service has no transport.** `interactor-ward` fans out through a `fanout_sink_t`, and
  today the only sink counts bytes for the benchmark. Until it grows a WebTransport sink, this
  client dials and nothing answers. That is the next piece of work and it belongs on the
  service side, not here.
- **`XRGridFabricManager` drops slices.** Its receive loop emits `entity_received` only when a
  datagram is exactly 100 bytes, so a 64-entity slice — the thing `fanout_one` actually sends —
  is discarded without a word. This project therefore reads `WebTransportPeer` directly and
  splits by 100 itself. The manager is the one that should be fixed; the wire contract is in
  `transport-fanout`'s README and it says batches, not single records.
