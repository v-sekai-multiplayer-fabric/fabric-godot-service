# This player's head and two hands, sent to the service.
#
# Sending your own tracked pose is the whole of what a client contributes. It is not authority
# and it is not simulation: the service decides where the cubes go and what everyone else is
# told, and this says only "here is where my headset and controllers are". The article's avatar
# is exactly these three, driven by tracking rather than by physics.
#
# Rate is 20 Hz to match the service's publish rate, and deliberately not the frame rate. A
# client that sent a pose every drawn frame would send four times what a 20 Hz zone can use, and
# the extra would be discarded by the tick that receives it.
#
# SPDX-License-Identifier: Apache-2.0
class_name LocalRig
extends Node3D

const CLASS_AVATAR := 2
const PART_HEAD := 0
const PART_LEFT_HAND := 1
const PART_RIGHT_HAND := 2

## The zone client. Poses go out over the same WebTransport session slices come in on, so the
## service already knows which subscriber they belong to and there is nothing to name.
@export var zone_client_path: NodePath

@export var head_path: NodePath
@export var left_hand_path: NodePath
@export var right_hand_path: NodePath

@export var send_rate_hz: float = 20.0

var _client: ZoneClient
var _parts: Array[Node3D] = []
var _accumulated := 0.0

# The session's own peer id, narrowed to the sixteen bits `class_owner` has for an owner. It
# arrives when the QUIC handshake finishes, so poses before that would be sent under owner zero
# and attributed to whoever really is zero.
var _owner_id := -1


func _ready() -> void:
	_client = get_node(zone_client_path)
	_client.owner_id_assigned.connect(func(id: int) -> void: _owner_id = id)
	_parts = [
		get_node(head_path),
		get_node(left_hand_path),
		get_node(right_hand_path),
	]


func _physics_process(delta: float) -> void:
	if send_rate_hz <= 0.0 or _owner_id < 0:
		return
	_accumulated += delta
	var period := 1.0 / send_rate_hz
	if _accumulated < period:
		return
	# One period's worth, not however many elapsed. A client that had been stalled and then sent
	# a burst of backdated poses would be telling the service its head was in several places.
	_accumulated = fmod(_accumulated, period)

	for part in range(_parts.size()):
		_client.send_pose(_encode(part, _parts[part]))


func _encode(part: int, node: Node3D) -> PackedByteArray:
	# `XRGridEntityPacket.encode` is the engine's own, against the layout `lean-entity-packet`
	# proves. It takes metres and gives back the hundred integral bytes; nothing here knows an
	# offset, and nothing here should learn one.
	var xform := node.global_transform
	return XRGridEntityPacket.encode(
		XRGridEntityPacket.PLAYER_ENTITY_BASE + _owner_id * 3 + part,
		xform.origin,
		Vector3.ZERO,  # a tracked pose has no velocity to declare; the service ghosts it
		xform.basis.get_rotation_quaternion(),
		CLASS_AVATAR,
		_owner_id,
		0,
		0,
		part
	)


