tool
class_name ConceptGraphTemplate
extends "custom_graph_edit.gd"

"""
A template is the NodeGraph edited from the bottom dock. It is stored in a cgraph (json) file and
can be shared accross multiple ConceptGraph nodes.
"""


signal output_ready
signal simulation_started
signal simulation_outdated
signal simulation_completed
signal thread_completed
signal json_ready


var concept_graph
var root: Spatial
var paused := false
var restart_generation := false
var node_library: ConceptNodeLibrary	# Injected from the concept graph

var _json_util = load(ConceptGraphEditorUtil.get_plugin_root_path() + "/src/thirdparty/json_beautifier/json_beautifier.gd")
var _node_pool := ConceptGraphNodePool.new()
var _thread_pool := ConceptGraphThreadPool.new()
var _thread: Thread
var _save_thread: Thread
var _save_queued := false
var _timer := Timer.new()
var _simulation_delay := 0.075
var _template_loaded := false
var _clear_cache_on_next_run := false
var _registered_resources := [] # References to Objects needing garbage collection
var _output_nodes := [] # Final nodes of the graph
var _output := [] # Nodes generated by the graph


func _init() -> void:
	connect("output_ready", self, "_on_output_ready")
	connect("thread_completed", self, "_on_thread_completed")
	connect("node_created", self, "_on_node_created")
	connect("node_deleted", self, "_on_node_deleted")

	_timer.one_shot = true
	_timer.autostart = false
	_timer.connect("timeout", self, "_run_generation")
	add_child(_timer)


"""
Remove all children and connections
"""
func clear() -> void:
	_template_loaded = false
	clear_editor()
	_output_nodes = []
	run_garbage_collection()


"""
Creates a node using the provided model and add it as child which makes it visible and editable
from the Concept Graph Editor
"""
func create_node(node: ConceptNode, data := {}, notify := true) -> ConceptNode:
	var new_node: ConceptNode = node.duplicate()
	new_node.offset = scroll_offset + Vector2(250, 150)
	new_node.thread_pool = _thread_pool

	if new_node.is_final_output_node():
		_output_nodes.append(new_node)

	add_child(new_node)
	_connect_node_signals(new_node)

	if data.has("name"):
		new_node.name = data["name"]
	if data.has("editor"):
		new_node.restore_editor_data(data["editor"])
	if data.has("data"):
		new_node.restore_custom_data(data["data"])

	if notify:
		emit_signal("graph_changed")
		emit_signal("simulation_outdated")

	return new_node


func duplicate_node(node: ConceptNode) -> GraphNode:
	var ref = node_library.create_node(node.unique_id)
	ref.restore_editor_data(node.export_editor_data())
	ref.restore_custom_data(node.export_custom_data())
	return ref


"""
Add custom properties in the ConceptGraph inspector panel to expose variables at the instance level.
This is used to change parameters on an instance without having to modify the template itself
(And thus modifying all the other ConceptGraph using the same template).
"""
func update_exposed_variables() -> void:
	var exposed_variables = []
	for c in get_children():
		if c is ConceptNode:
			var variables = c.get_exposed_variables()
			if not variables:
				continue
			for v in variables:
				v.name = "Template/" + v.name
				v.type = ConceptGraphDataType.to_variant_type(v.type)
				exposed_variables.append(v)

	concept_graph.update_exposed_variables(exposed_variables)


"""
Get exposed variable from the inspector
"""
func get_value_from_inspector(name: String):
	return concept_graph.get("Template/" + name)


"""
Clears the cache of every single node in the template. Useful when only the inputs changes
and node the whole graph structure itself. Next time get_output is called, every nodes will
recalculate their output
"""
func clear_simulation_cache() -> void:
	for node in get_children():
		if node is ConceptNode:
			node.clear_cache()
	run_garbage_collection()
	_clear_cache_on_next_run = false


"""
This is the exposed API to run the simulation but doesn't run it immediately in case it get called
multiple times in a very short interval (Moving or resizing an input can cause this).
Actual simulation happens in _run_generation
"""
func generate(force_full_simulation := false) -> void:
	if paused:
		return
	_timer.start(_simulation_delay)
	_clear_cache_on_next_run = _clear_cache_on_next_run or force_full_simulation
	emit_signal("simulation_started")


"""
Returns the final result generated by the whole graph
"""
func get_output() -> Array:
	return _output


"""
Opens a cgraph file, reads its contents and recreate a node graph from there
"""
func load_from_file(path: String, soft_load := false) -> void:
	if not node_library or not path or path == "":
		return

	_template_loaded = false
	if soft_load:	# Don't clear, simply refresh the graph edit UI without running the sim
		clear_editor()
	else:
		clear()

	# Open the file and read the contents
	var file = File.new()
	file.open(path, File.READ)
	var json = JSON.parse(file.get_as_text())
	if not json or not json.result:
		print("Failed to parse json")
		return	# Template file is either empty or not a valid Json. Ignore

	# Abort if the file doesn't have node data
	var graph: Dictionary = json.result
	if not graph.has("nodes"):
		return

	# For each node found in the template file
	var node_list = node_library.get_list()
	for node_data in graph["nodes"]:
		if not node_data.has("type"):
			continue

		var type = node_data["type"]
		if not node_list.has(type):
			print("Error: Node type ", type, " could not be found.")
			continue

		# Get a graph node from the node_library and use it as a model to create a new one
		var node_instance = node_list[type]
		create_node(node_instance, node_data, false)

	for c in graph["connections"]:
		# TODO: convert the to/from ports stored in file to actual port
		connect_node(c["from"], c["from_port"], c["to"], c["to_port"])
		get_node(c["to"]).emit_signal("connection_changed")

	_template_loaded = true


func save_to_file(path: String) -> void:
	var graph := {}
	# TODO : Convert the connection_list to an ID connection list
	graph["connections"] = get_connection_list()
	graph["nodes"] = []

	for c in get_children():
		if c is ConceptNode:
			var node = {}
			node["name"] = c.get_name()
			node["type"] = c.unique_id
			node["editor"] = c.export_editor_data()
			node["data"] = c.export_custom_data()
			graph["nodes"].append(node)

	if not _save_thread:
		_save_thread = Thread.new()

	if _save_thread.is_active():
		_save_queued = true
		return

	_save_thread.start(self, "_beautify_json", to_json(graph))

	yield(self, "json_ready")

	var json = _save_thread.wait_to_finish()
	var file = File.new()
	file.open(path, File.WRITE)
	file.store_string(json)
	file.close()

	if _save_queued:
		_save_queued = false
		save_to_file(path)


"""
Manual garbage collection handling. Before each generation, we clean everything the graphnodes may
have created in the process. Because graphnodes hand over their result to the next one, they can't
handle the removal themselves as they don't know if the resource is still in use or not.
"""
func register_to_garbage_collection(resource):
	if resource is Object and not resource is Reference:
		_registered_resources.append(weakref(resource))


"""
Iterate over all the registered resources and free them if they still exist
"""
func run_garbage_collection():
	for res in _registered_resources:
		var resource = res.get_ref()
		if resource:
			if resource is Node:
				var parent = resource.get_parent()
				if parent:
					parent.remove_child(resource)
				resource.queue_free()
			elif resource is Object:
				resource.call_deferred("free")
	_registered_resources = []


"""
_run_generation makes sure there's no active thread running before starting a new generation.
Called from _timer (on timeout event).
"""
func _run_generation() -> void:
	if not _thread:
		_thread = Thread.new()

	if _thread.is_active():
		# Let the thread finish (as there's no way to cancel it) and start the generation again
		restart_generation = true
		return

	restart_generation = false

	if _clear_cache_on_next_run:
		clear_simulation_cache()

	if ProjectSettings.get(ConceptGraphSettings.MULTITHREAD_ENABLED):
		_thread.start(self, "_run_generation_threaded")
	else:
		_run_generation_threaded()


# Useless parameter needed otherwise the thread wont run the function
func _run_generation_threaded(_var = null) -> void:
	if _output_nodes.size() == 0:
		if _template_loaded:
			print("Error : No output node found in ", get_parent().get_name())
			call_deferred("emit_signal", "thread_completed")

	_output = []
	var node_output
	for node in _output_nodes:
		if not node:
			_output_nodes.erase(node)
			continue

		node_output = node.get_output(0)
		if node_output == null:
			continue
		if not node_output is Array:
			node_output = [node_output]

		_output += node_output

	# Call deferred causes the main thread to emit the signal, won't work otherwise
	call_deferred("emit_signal", "thread_completed")


func _beautify_json(json: String) -> String:
	var res = _json_util.beautify_json(json)
	call_deferred("emit_signal", "json_ready")
	return res


func _on_thread_completed() -> void:
	if ProjectSettings.get(ConceptGraphSettings.MULTITHREAD_ENABLED):
		_thread.wait_to_finish()
	if restart_generation:
		generate()
	else:
		emit_signal("simulation_completed")


func _on_node_created(node) -> void:
	if node.is_final_output_node():
		_output_nodes.append(node)


func _on_node_deleted(node) -> void:
	if node.is_final_output_node():
		_output_nodes.erase(node)


# Preserving 3.1 compatibility. Otherwise, just add a default "= null" to the node parameter
func _on_node_changed_zero():
	_on_node_changed(null, false)


func _on_node_changed(_node: ConceptNode, replay_simulation := false) -> void:
	# Prevent regeneration hell while loading the template from file
	if not _template_loaded:
		return

	emit_signal("graph_changed")
	if replay_simulation:
		emit_signal("simulation_outdated")
	update()
