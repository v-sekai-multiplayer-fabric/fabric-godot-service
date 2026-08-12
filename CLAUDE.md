# fabric-godot-service

The XR client for one zone of the multiplayer fabric. It connects to `fabric-physics-service`
over WebTransport, draws the entities that service sends, and sends back this player's head and
two hands.

`README.md` gives the design. Record decisions in the `multiplayer-fabric-manuals` repository.
`CITATION.cff` says what this repository is built on; add a reference there when you add a
dependency here.

## It is only a client

This repository MUST NOT simulate, own, or decide anything about the zone.

- Do NOT add a `RigidBody3D`, a `PhysicsBody3D`, or any collision shape for a prop. The service
  is authoritative. A body here is a second simulation that disagrees with the first one every
  frame.
- Do NOT extrapolate past the newest snapshot. Interpolate between the last two and clamp.
  Running ahead is prediction, and prediction belongs to the service that owns authority.
- Do NOT invent state the wire does not carry. Three tracked poses is the whole avatar; a torso
  drawn between them is this client guessing.
- The only thing this project produces is its own head and hand poses, at 20 Hz.

## The transport is the engine's

Use `WebTransportPeer` from `modules/http3`. Do NOT open a raw UDP socket, add ENet, or bring in
another transport: the fabric speaks WebTransport and a second one is a second thing to keep in
step.

State goes as QUIC datagrams, unreliable. A late snapshot is worse than a lost one — the next
tick supersedes it in 50 ms. Reliable things open a stream.

## The packet is not ours to define

Decode with `XRGridEntityPacket.decode` and encode with `XRGridEntityPacket.encode`.

No file here may contain a field offset, a packet size other than `XRGridEntityPacket.PACKET_SIZE`,
or a unit conversion between micrometres and metres. The layout is proved in `lean-entity-packet`
and emitted from there; `decode` already returns metres.

A slice is back-to-back 100-byte records with no framing and the count is `len / 100`. A
datagram whose length is not a multiple of 100 is malformed, not short. Drop it and say so.

## Build

The engine is `fabric-godot-core` at branch `gyre`, built `precision=double`. A single-precision
build MUST NOT be used: positions are int64 absolute micrometres over a zone that can be
kilometres across.

```sh
godot --path . -- --zone=127.0.0.1:9500
```

Runs in XR when a headset is present and flat when it is not. Both paths must keep working —
the flat one is how this gets debugged.
