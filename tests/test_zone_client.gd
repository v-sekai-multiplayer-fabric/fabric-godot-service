# What the client does with a slice, checked without a service.
#
#   godot --headless --path . --script res://tests/test_zone_client.gd
#
# The service has no transport yet, so there is nothing to connect to. That is no reason to leave
# the decode path untested: the client's whole job is turning a slice into nodes in the right
# places, and a slice is bytes — it does not care whether a socket or this file produced them.
#
# The bytes come from `XRGridEntityPacket.encode`, the engine's own, which is the same layout
# `lean-entity-packet` proves and the same one the fan-out edge writes. A test that built its own
# hundred bytes would pass while disagreeing with the wire, which is the failure this whole
# arrangement exists to make impossible.
#
# SPDX-License-Identifier: Apache-2.0
extends SceneTree

const CLASS_PROP := 1
const CLASS_AVATAR := 2

var failures := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    %s" % what)
	else:
		failures += 1
		printerr("  FAIL  %s" % what)


func near(a: float, b: float, tol := 0.001) -> bool:
	return absf(a - b) <= tol


func _init() -> void:
	print("zone client, against slices it did not receive")

	var zone: Node3D = load("res://scenes/zone.tscn").instantiate()
	root.add_child(zone)

	var zc: Node = zone.get_node("ZoneClient")
	var world: Node3D = zone.get_node("World")

	# Two props and one other player's three tracked parts, as the service would send them.
	var slice := PackedByteArray()
	slice += XRGridEntityPacket.encode(101, Vector3(1.5, 0.2, -2.0), Vector3.ZERO,
		Quaternion.IDENTITY, CLASS_PROP, 0, 0, 0, 0)
	slice += XRGridEntityPacket.encode(102, Vector3(-3.0, 0.2, 4.25), Vector3.ZERO,
		Quaternion.IDENTITY, CLASS_PROP, 0, 0, 0, 0)
	slice += XRGridEntityPacket.encode(2000021, Vector3(0.0, 1.6, -5.0), Vector3.ZERO,
		Quaternion.IDENTITY, CLASS_AVATAR, 7, 0, 0, 0)
	slice += XRGridEntityPacket.encode(2000022, Vector3(-0.25, 1.1, -5.4), Vector3.ZERO,
		Quaternion.IDENTITY, CLASS_AVATAR, 7, 0, 0, 1)
	slice += XRGridEntityPacket.encode(2000023, Vector3(0.25, 1.1, -5.4), Vector3.ZERO,
		Quaternion.IDENTITY, CLASS_AVATAR, 7, 0, 0, 2)

	check(slice.size() == 5 * XRGridEntityPacket.PACKET_SIZE,
		"five records is %d bytes" % slice.size())

	zc._apply_slice(slice)
	# Force the interpolation to the newest snapshot. `_process` would do this a frame later;
	# a test that waited would be timing the renderer rather than checking the decode.
	zc._snapshot_at = Time.get_ticks_msec() / 1000.0 - 1.0
	zc._process(0.0)

	# Two props, and one avatar rig for the one owner. Five records is not five nodes: three of
	# them are parts of one person, which is what `owner_id` and `sub_index` are for.
	var props := 0
	var rigs := 0
	for c in world.get_children():
		if (c.name as String).begins_with("prop_"):
			props += 1
		elif (c.name as String).begins_with("avatar_"):
			rigs += 1
	check(props == 2, "two props from two prop records (got %d)" % props)
	check(rigs == 1, "three avatar records make one rig (got %d)" % rigs)

	var prop101: Node3D = world.get_node_or_null("prop_101")
	check(prop101 != null, "prop 101 exists")
	if prop101:
		# Metres, not micrometres. `decode` converts, so a client that divided again would put
		# this at 0.0000015 and every prop in a heap at the origin.
		check(near(prop101.position.x, 1.5) and near(prop101.position.y, 0.2)
			and near(prop101.position.z, -2.0),
			"prop 101 is at 1.5, 0.2, -2.0 (got %v)" % prop101.position)

	var rig: Node3D = world.get_node_or_null("avatar_7")
	check(rig != null, "owner 7 has a rig")
	if rig:
		var head: Node3D = rig.get_node("Head")
		var left: Node3D = rig.get_node("LeftHand")
		var right: Node3D = rig.get_node("RightHand")
		# `sub_index` is what tells three identical-looking records apart. If it were dropped on
		# the wire they would all land on the head, which is the bug this asserts against.
		check(near(head.position.y, 1.6), "sub_index 0 drove the head (y=%.3f)" % head.position.y)
		check(near(left.position.x, -0.25), "sub_index 1 drove the left hand (x=%.3f)" % left.position.x)
		check(near(right.position.x, 0.25), "sub_index 2 drove the right hand (x=%.3f)" % right.position.x)

	# A slice is whole records by construction, so a length that is not a multiple of 100 is
	# malformed rather than short. Trimming it would put a fabricated entity in the world.
	var before := world.get_child_count()
	zc._apply_slice(slice.slice(0, 150))
	check(world.get_child_count() == before,
		"a 150-byte slice is refused whole (children %d, was %d)"
			% [world.get_child_count(), before])

	# An entity the newest slice does not mention has left interest, not existence. It is hidden
	# and kept, because the service will send it again under the same id when the player walks
	# back — freeing it would make every return a re-spawn.
	var narrower := PackedByteArray()
	narrower += XRGridEntityPacket.encode(101, Vector3(1.5, 0.2, -2.0), Vector3.ZERO,
		Quaternion.IDENTITY, CLASS_PROP, 0, 0, 0, 0)
	zc._apply_slice(narrower)
	check(world.get_node_or_null("prop_102") != null, "prop 102 is kept when interest drops it")
	check(not (world.get_node("prop_102") as Node3D).visible, "and hidden rather than drawn")
	check((world.get_node("prop_101") as Node3D).visible, "while prop 101 stays visible")

	if failures > 0:
		printerr("zone client: %d failed" % failures)
		quit(1)
	else:
		print("zone client: every check passed")
		quit(0)
