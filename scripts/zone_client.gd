# The zone, as this client sees it.
#
# The transport is `WebTransportPeer` from the engine's own `modules/http3` — picoquic, QUIC
# datagrams for state and bidi streams for anything reliable. Not a raw UDP socket: the zone
# speaks WebTransport, and a client that opened its own socket would be a second transport to
# keep in step with the one the fabric already has.
#
# What arrives is a slice: back-to-back 100-byte XRGridEntityPacket records with no framing at
# all, exactly as `fanout_one` writes them in `fabric-fanout-edge`. The count is recovered as
# `len / 100`. That is the wire contract — one datagram is one message, and its FIN or its
# length is the boundary, so there is no header here to get out of step with.
#
# Decoding is `XRGridEntityPacket.decode`, the engine's own static method, against the layout
# `lean-entity-packet` proves. This file knows no offsets and must not learn any.
#
# SPDX-License-Identifier: Apache-2.0
class_name ZoneClient
extends Node

## Where the physics service is. `--zone=host:port` overrides it.
@export var zone_address: String = "127.0.0.1"
@export var zone_port: int = 9500
## The WebTransport path the zone is served on.
@export var zone_path: String = "/zone"

## Where props and remote avatars are parented.
@export var world_path: NodePath

# There is no unit conversion in this file on purpose. The wire is int64 absolute micrometres
# and `XRGridEntityPacket.decode` has already turned that into metres of double before anything
# here sees it. Dividing again renders the zone a thousand times too small and looks like a
# physics problem.

# `class_owner` is `(class << 24) | owner`, so the class is the top byte. The service sends 1
# for a simulated prop and 2 for a tracked avatar part; `sub_index` says which part, and the
# article's avatar has three of them.
const CLASS_PROP := 1
const CLASS_AVATAR := 2
const PART_HEAD := 0
const PART_LEFT_HAND := 1
const PART_RIGHT_HAND := 2

signal owner_id_assigned(owner_id: int)

var _peer := WebTransportPeer.new()
var _world: Node3D
var _props: Dictionary = {}    # global_id -> Node3D
var _avatars: Dictionary = {}  # owner_id -> {part -> Node3D}

# The last two snapshots, so `_process` can interpolate. The service publishes at 20 Hz and the
# headset draws at 72 or 90; a client that snapped to the newest snapshot would judder at 20 Hz
# however fast it drew.
var _from: Dictionary = {}
var _to: Dictionary = {}
var _snapshot_at := 0.0
var _snapshot_period := 1.0 / 20.0

var _connected := false
var _owner_id := 0

var _prop_scene := preload("res://scenes/prop.tscn")
var _avatar_scene := preload("res://scenes/remote_avatar.tscn")


func _ready() -> void:
	_world = get_node(world_path)
	_read_cmdline()

	var err := _peer.create_client(zone_address, zone_port, zone_path)
	if err != OK:
		push_error("no WebTransport session to https://%s:%d%s (%d)" %
			[zone_address, zone_port, zone_path, err])
		return

	# State goes as QUIC datagrams. A snapshot that arrived late is worse than one that did not
	# arrive: the next tick supersedes it in 50 ms, and retransmitting it would deliver a stale
	# pose behind a fresh one. Anything that must not be lost opens a stream instead.
	_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	print("dialling zone at %s:%d%s" % [zone_address, zone_port, zone_path])


func _read_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--zone="):
			var spec: String = arg.split("=", true, 1)[1]
			var parts := spec.split(":")
			if parts.size() > 0:
				zone_address = parts[0]
			if parts.size() > 1:
				zone_port = int(parts[1])


func _physics_process(_delta: float) -> void:
	_peer.poll()

	if not _connected:
		if _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			return
		_connected = true
		# The peer id the session was given is this client's owner on the wire. It is not chosen
		# here: two clients that named themselves would eventually pick the same number, and
		# `class_owner` has sixteen bits of owner and no room to disambiguate afterwards.
		_owner_id = _peer.get_unique_id() & 0xFFFF
		owner_id_assigned.emit(_owner_id)
		print("zone session open, owner %d" % _owner_id)

	var got_one := false
	# Drain rather than take one datagram a frame. At 20 Hz into a 90 Hz client there is usually
	# nothing and occasionally a backlog, and taking one per frame would fall further behind
	# every time the network hiccuped.
	while _peer.get_available_packet_count() > 0:
		_apply_slice(_peer.get_packet())
		got_one = true
	if got_one:
		_snapshot_at = Time.get_ticks_msec() / 1000.0


func send_pose(packet: PackedByteArray) -> void:
	if _connected:
		_peer.put_packet(packet)


func get_owner_id() -> int:
	return _owner_id


func _apply_slice(bytes: PackedByteArray) -> void:
	var size := XRGridEntityPacket.PACKET_SIZE
	if bytes.is_empty() or bytes.size() % size != 0:
		# Not a short slice — a malformed one. A slice is whole records by construction, so a
		# remainder means something framed the datagram, and guessing which end to trim would
		# put a fabricated entity in the world.
		push_warning("dropped a slice of %d bytes, not a multiple of %d" % [bytes.size(), size])
		return

	_from = _to
	_to = {}
	for i in range(bytes.size() / size):
		var decoded: Dictionary = XRGridEntityPacket.decode(bytes.slice(i * size, (i + 1) * size))
		if decoded.is_empty():
			continue
		_to[decoded["global_id"]] = decoded
		_ensure_node(decoded)

	# Entities the newest slice did not mention are out of interest, not gone. The service sends
	# the nearest sixty-four and nothing else, so a prop going quiet means the player walked away
	# from it: hiding is right and freeing is not, because it comes back under the same id.
	for gid in _props:
		(_props[gid] as Node3D).visible = _to.has(gid)


func _ensure_node(d: Dictionary) -> void:
	if d["entity_class"] == CLASS_AVATAR:
		var other: int = d["owner_id"]
		# Our own three come back from the service like everyone else's. Drawing them would put
		# a second head inside this one's camera.
		if other == _owner_id:
			return
		if not _avatars.has(other):
			var rig: Node3D = _avatar_scene.instantiate()
			rig.name = "avatar_%d" % other
			_world.add_child(rig)
			_avatars[other] = {
				PART_HEAD: rig.get_node("Head"),
				PART_LEFT_HAND: rig.get_node("LeftHand"),
				PART_RIGHT_HAND: rig.get_node("RightHand"),
			}
		return

	var gid: int = d["global_id"]
	if not _props.has(gid):
		var prop: Node3D = _prop_scene.instantiate()
		prop.name = "prop_%d" % gid
		_world.add_child(prop)
		_props[gid] = prop


func _process(_delta: float) -> void:
	# Where we are between the two snapshots we hold. Clamped at 1 rather than extrapolated: a
	# client running ahead of the newest state it has is predicting, and prediction belongs to
	# the service that owns authority, not to a renderer guessing.
	var t := 1.0
	if _snapshot_period > 0.0:
		t = clampf((Time.get_ticks_msec() / 1000.0 - _snapshot_at) / _snapshot_period, 0.0, 1.0)

	for gid in _to:
		var b: Dictionary = _to[gid]
		var node := _node_for(b)
		if node == null:
			continue
		var a: Dictionary = _from.get(gid, b)
		node.position = (a["position"] as Vector3).lerp(b["position"], t)
		node.quaternion = (a["rotation"] as Quaternion).slerp(b["rotation"], t)


func _node_for(d: Dictionary) -> Node3D:
	if d["entity_class"] == CLASS_AVATAR:
		return (_avatars.get(d["owner_id"], {}) as Dictionary).get(d["sub_index"], null)
	return _props.get(d["global_id"], null)
