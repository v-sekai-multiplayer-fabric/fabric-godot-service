# transport-client

The desktop test client for one zone of the multiplayer fabric. It connects to
`interactor-ward` over WebTransport, draws the entities that service sends, and sends
back this player's head and two hands.

Desktop, not a headset. `XRGridFlatscreenController` drives the camera and both hands from
mouse, WASD and a gamepad, and it is the engine's own class rather than a stand-in — it is what
the XR build already falls back to when no OpenXR runtime initialises. What it moves are three
Node3Ds, which is what a head and two hands are on the wire, so nothing above it and nothing
across the network can tell the difference.

`README.md` says what this is; `WIRE.md` gives the design. Record decisions in the `multiplayer-fabric-manuals` repository.
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
or a unit conversion between micrometres and metres. The layout is proved in `contract-entity-packet`
and emitted from there; `decode` already returns metres.

A slice is back-to-back 100-byte records with no framing and the count is `len / 100`. A
datagram whose length is not a multiple of 100 is malformed, not short. Drop it and say so.

## The rig's node names are a contract

`XRGridFlatscreenController` looks up `XRCamera3D`, `hand_left` and `hand_right` under its
parent, by name. Renaming any of them does not error — it drives nothing, and the client sends
three poses that never move. Do NOT rename them.

`XRCamera3D` is a plain `Camera3D`. The controller casts to `Camera3D` and never asks for an XR
one, so the desktop build needs no XR node in the tree.

## OpenXR stays off

`openxr/enabled=false`. With it on, an installed runtime claims the session and the flatscreen
controller stands down — it checks whether OpenXR initialised and deactivates itself if it did,
so a headset plugged in for something else would silently take over the test client.

Keep `xr/actions.tres`. It is what the headset build needs, it costs nothing while OpenXR is
off, and deleting it makes putting the headset back a rewrite rather than a flag.

## The MCP bridge

`addons/vsekai_godot_mcp` is vendored, and both halves are on: the editor plugin on **8788**,
and `MCPRuntime` as an autoload inside the running game on **8789**.

Two ports, deliberately. The ordinary way to run this is to press play in an editor that is
already open, and when they shared 8788 the game lost the bind while an MCP client went on
questioning the editor and believing it had reached the game — wrong answers, not an error.
`--mcp-port=` or `GODOT_MCP_PORT` moves the runtime one.

Ask the *running* game, not the editor, when the question is what arrived. A node's real
transform is the difference between "the packet decoded" and "the cube is where the service put
it", and nothing above the socket can tell you the second.

## Build

The engine is `entities-godot` at branch `gyre`, built `precision=double`. A single-precision
build MUST NOT be used: positions are int64 absolute micrometres over a zone that can be
kilometres across.

```sh
godot --path . -- --zone=127.0.0.1:9500
```
