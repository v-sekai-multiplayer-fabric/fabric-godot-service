# fabric-godot-service

The XR client for one zone. It connects to `fabric-physics-service`, draws what that service
says is nearby, and sends back this player's head and two hands.

**It is only a client.** Nothing here simulates, owns, or decides anything. There is no
`RigidBody` in the project and there is not going to be one: the service is authoritative over
every prop, and a physics body on this side would be a second simulation disagreeing with the
first one every frame — which is the divergence a server-authoritative design exists to remove.
What this project produces is three poses a tick. Everything else it does is drawing.

## Running it

```sh
godot --path . -- --zone=127.0.0.1:9500
```

With a headset attached, `XRGridXROrigin` initialises OpenXR and puts the viewport in XR. With
none it runs flat on the desk, which is how it is debugged.

The engine is `fabric-godot-core` at branch `gyre`, built with `precision=double`. That is not
optional: positions on the wire are int64 absolute micrometres so a zone can be kilometres
across, and a single-precision build puts things in visibly wrong places once it is.

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
a field offset, and none should learn one — the layout is proved in `lean-entity-packet` and
emitted from there.

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
`fabric-physics-interactor`, where the rollback loop is going. A renderer that guessed would be
a second opinion about where a cube is, which is the thing the whole design refuses.

## Two things that are not wired yet

- **The service has no transport.** `fabric-physics-service` fans out through a
  `fanout_sink_t`, and today the only sink counts bytes for the benchmark. Until it grows a
  WebTransport sink, this client dials and nothing answers. That is the next piece of work and
  it belongs on the service side, not here.
- **`XRGridFabricManager` drops slices.** Its receive loop emits `entity_received` only when a
  datagram is exactly 100 bytes, so a 64-entity slice — the thing `fanout_one` actually sends —
  is discarded without a word. This project therefore reads `WebTransportPeer` directly and
  splits by 100 itself. The manager is the one that should be fixed; the wire contract is in
  `fabric-fanout-edge`'s README and it says batches, not single records.
