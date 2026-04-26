# Convenience headless test runner.
#
# Usage (from repo root):
#   godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests/ -gexit -ginclude_subdirs
#
# Or with the .gutconfig.json in repo root:
#   godot --headless -s addons/gut/gut_cmdln.gd -gconfig=.gutconfig.json
#
# This file itself is a no-op script; it exists as a documented anchor so
# new contributors can `Read` it and learn the headless invocation.
extends SceneTree

func _init() -> void:
	print("Use: godot --headless -s addons/gut/gut_cmdln.gd -gconfig=.gutconfig.json")
	quit(0)
