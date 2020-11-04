extends Control
class_name NodeSidebar


# The Node sidebar is a panel shown on the left side of the graph editor.
# From there you can change the node locals value but also decide to hide or
# show individual parts of the graph UI. This is useful for nodes having 
# a lot of parameters (like the noises nodes) but you don't connect them to
# anything. Hiding them makes the node appear smaller and saves space on the
# graph. This is purely visual, the node keeps behaving exactly the same way.


var _current: ConceptNode


onready var _default: Control = $MarginContainer/DefaultContent
onready var _properties: Control = $MarginContainer/Properties
onready var _name: Label = $MarginContainer/Properties/NameLabel
onready var _input_label: Label = $MarginContainer/Properties/InputLabel
onready var _output_label: Label = $MarginContainer/Properties/OutputLabel
onready var _extra_label: Label = $MarginContainer/Properties/ExtraLabel
onready var _inputs: Control = $MarginContainer/Properties/Inputs
onready var _outputs: Control = $MarginContainer/Properties/Outputs
onready var _extras: Control = $MarginContainer/Properties/Extras



func clear() -> void:
	NodeUtil.remove_children(_inputs)
	NodeUtil.remove_children(_outputs)
	NodeUtil.remove_children(_extras)
	_current = null
	_name.text = ""
	_default.visible = true
	_properties.visible = false


func _rebuild_ui() -> void:
	# Show the default screen and abort if no nodes are selected
	if not _current:
		_default.visible = true
		_properties.visible = false
		return

	# Show the property screen
	_default.visible = false
	_properties.visible = true
	_name.text = _current.display_name

	# Create a new SidebarProperty object for each slots. They rely on the 
	# safe GraphNodeComponents used by the ConceptNodeUi class.
	for idx in _current._inputs.keys():
		var slot = _current._inputs[idx]
		var name = slot["name"]
		var type = slot["type"]
		var opts = slot["options"]
		var hidden = slot["hidden"]
		var value = _current._get_default_gui_value(idx)
		var ui: SidebarProperty = preload("property.tscn").instance()
		_inputs.add_child(ui)
		ui.create_input(name, type, value, idx, opts)
		ui.set_property_visibility(hidden)
		Signals.safe_connect(ui, "value_changed", self, "_on_sidebar_value_changed")
		Signals.safe_connect(ui, "property_visibility_changed", self, "_on_input_property_visibility_changed", [idx])

	# Outputs are simpler and only require the name and type.
	for idx in _current._outputs.keys():
		var slot: Dictionary = _current._outputs[idx]
		var name = slot["name"]
		var type = slot["type"]
		var hidden = slot["hidden"]
		var ui: SidebarProperty = preload("property.tscn").instance()
		_outputs.add_child(ui)
		ui.create_generic(name, type)
		ui.set_property_visibility(hidden)
		Signals.safe_connect(ui, "property_visibility_changed", self, "_on_output_property_visibility_changed", [idx])
	
	# For custom components (like 2D preview or other things that don't fall in
	# the previous categories. We just display a name.
	for idx in _current._extras.keys():
		var extra = _current._extras[idx]
		var name = Constants.get_readable_name(extra["type"])
		var hidden = extra["hidden"]
		var ui: SidebarProperty = preload("property.tscn").instance()
		_extras.add_child(ui)
		ui.create_generic(name, -1)
		ui.set_property_visibility(hidden)
		Signals.safe_connect(ui, "property_visibility_changed", self, "_on_extra_property_visibility_changed", [idx])
	
	_input_label.visible = _inputs.get_child_count() != 0
	_output_label.visible = _outputs.get_child_count() != 0
	_extra_label.visible = _extras.get_child_count() != 0


func _on_node_selected(node) -> void:
	if not node:
		return
	
	if _current:
		Signals.safe_disconnect(_current, "gui_value_changed", self, "_on_node_value_changed")
		
	clear()
	_current = node
	_rebuild_ui()
	Signals.safe_connect(_current, "gui_value_changed", self, "_on_node_value_changed")


func _on_node_deleted(node) -> void:
	if node == _current:
		clear()


# Sync changes from the graph node to the side bar
func _on_node_value_changed(value, idx: int) -> void:
	for child in _inputs.get_children():
		if child is SidebarProperty and child.get_index() == idx:
			child.set_value(value)
			return


# Sync changes from the sidebar to the graphnode
func _on_sidebar_value_changed(value, idx: int) -> void:
	if not _current:
		return # Should not happen
	
	_current.set_default_gui_value(idx, value)


func _on_input_property_visibility_changed(visible: bool, index: int) -> void:
	_current.set_input_visibility(index, visible)


func _on_output_property_visibility_changed(visible: bool, index: int) -> void:
	_current.set_output_visibility(index, visible)


func _on_extra_property_visibility_changed(visible: bool, index: int) -> void:
	_current.set_extra_visibility(index, visible)
