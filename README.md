# transport-client

The desktop test client for one zone. It connects to `interactor-ward`, draws what that service says is nearby, and sends back this player's head and two hands.

No headset. `XRGridFlatscreenController` drives the camera and both hands from mouse, WASD and a gamepad — the engine's own class, and the same one the XR build falls back to when no OpenXR runtime initialises, so it is not a stand-in. What it moves are three Node3Ds, which is what a head and two hands are on the wire, so nothing above it and nothing across the network can tell the difference.

**It is only a client.** Nothing here simulates, owns, or decides anything. There is no `RigidBody` in the project and there is not going to be one: the service is authoritative over every prop, and a physics body on this side would be a second simulation disagreeing with the first one every frame — which is the divergence a server-authoritative design exists to remove. What this project produces is three poses a tick. Everything else it does is drawing.

## Running it

```sh
godot --path . -- --zone=127.0.0.1:9500
```

Mouse looks, WASD walks, the hands follow the camera. OpenXR is off in `project.godot`: with it on, an installed runtime claims the session and the flatscreen controller stands down, so a headset plugged in for something else would silently take over the test client. `xr/actions.tres` stays in the tree, so putting the headset back is a flag rather than a rewrite.

The engine is `entities-godot` at branch `gyre`, built with `precision=double`. That is not optional: positions on the wire are int64 absolute micrometres so a zone can be kilometres across, and a single-precision build puts things in visibly wrong places once it is.

## The rest

`WIRE.md` carries the wire and the reasoning: the datagram layout and why state is unreliable, what a player is on the wire, why the client interpolates rather than predicts, how to drive it over MCP, and the two things that are not wired yet.
