tool
class_name ConceptNode
extends GraphNode

"""
The base class for every nodes you can add in the Graph editor. It provides a basic UI framework
for nodes with simple parameters as well as a caching system and other utilities.
"""


signal delete_node
signal node_changed
signal input_changed
signal connection_changed
signal all_inputs_ready
signal output_ready


var unique_id := "concept_node"
var display_name := "ConceptNode"
var category := "No category"
var description := "A brief description of the node functionality"
var node_pool: ConceptGraphNodePool # Injected from template
var thread_pool: ConceptGraphThreadPool # Injected from template
var output := []

var _inputs := {}
var _outputs := {}
var _hboxes := []
var _dynamic_inputs := {}
var _btn_container: HBoxContainer # Used for dynamic input system
var _resize_timer := Timer.new()
var _initialized := false	# True when all enter_tree initialization is done
var _generation_requested := false # True after calling prepare_output once
var _output_ready := false # True when the background generation was completed


func _enter_tree() -> void:
	if _initialized:
		return
	if not EditorPlugin:
		return

	_generate_default_gui()
	_setup_slots()

	_resize_timer.one_shot = true
	_resize_timer.autostart = false
	add_child(_resize_timer)

	_connect_signals()
	_reset_output()
	_initialized = true


# Called from the template when the user copy paste nodes
func init_from_node(node: ConceptNode) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()

	unique_id = node.unique_id
	display_name = node.display_name
	category = node.category
	description = node.description
	node_pool = node.node_pool
	thread_pool = node.thread_pool

	_inputs = node._inputs
	_outputs = node._outputs
	_hboxes = []

	for b in node._hboxes:
		var d = b.duplicate()
		add_child(d)
		_hboxes.append(d)

	_setup_slots()
	_generate_default_gui_style()
	_initialized = true


"""
Override and make it return true if your node should be instanced from a scene directly.
Scene should have the same name as the script and use a .tscn extension.
When using a custom gui, you lose access to the default gui. You have to define slots and undo
redo yourself but you have complete control over the node appearance and behavior.
"""
func has_custom_gui() -> bool:
	return false


func is_output_ready() -> bool:
	return _output_ready


"""
Call this first to generate everything in the background first. This method then emits a signal
when the results are ready. Outputs can then be fetched using the get_output method.
"""
func prepare_output() -> void:
	if not _initialized or not get_parent():
		return

	# If the output was already generated, skip the whole function and notify directly
	if is_output_ready():
		call_deferred("emit_signal", "output_ready")
		return

	if _generation_requested:	# Prepare output was already called
		return

	_generation_requested = true

	if not _request_inputs_to_get_ready():
		yield(self, "all_inputs_ready")

	call_deferred("_run_background_generation") # Single thread execution
	#thread_pool.submit_task(self, "_run_background_generation") # Broken multithread execution


"""
Return how many total inputs slots are available on this node. Includes the dynamic ones as well.
"""
func get_inputs_count() -> int:
	return _inputs.size()


"""
Returns the associated data to the given slot index. It either comes from a connected input node,
or from a local control field in the case of a simple type (float, string)
"""
func get_input(idx: int, default = []) -> Array:
	var parent = get_parent()
	if not parent:
		return default

	var input: Dictionary = parent.get_left_node(self, idx)
	if input.has("node"):	# Input source connected, ignore local data
		return input["node"].get_output(input["slot"], default)

	if has_custom_gui():
		var output = _get_input(idx)
		if output == null:
			return default
		return output

	# If no source is connected, check if it's a base type with a value defined on the node itself
	match _inputs[idx]["type"]:
		ConceptGraphDataType.BOOLEAN:
			return [_hboxes[idx].get_node("CheckBox").pressed]
		ConceptGraphDataType.SCALAR:
			return [_hboxes[idx].get_node("SpinBox").value]
		ConceptGraphDataType.STRING:
			if _hboxes[idx].has_node("LineEdit"):
				return [_hboxes[idx].get_node("LineEdit").text]
			elif _hboxes[idx].has_node("OptionButton"):
				var btn = _hboxes[idx].get_node("OptionButton")
				return [btn.get_item_text(btn.selected)]

	return default # Not a base type and no source connected


"""
By default, every input and output is an array. This is just a short hand with all the necessary
checks that returns the first value of the input.
"""
func get_input_single(idx: int, default = null):
	var input = get_input(idx)
	if input == null or input.size() == 0 or input[0] == null:
		return default
	return input[0]


"""
Returns what the node generates for a given slot
This method ensure the output is not calculated more than one time per run. It's useful if the
output node is connected to more than one node. It ensure the results are the same and save
some performance
"""
func get_output(idx: int, default := []) -> Array:
	if not is_output_ready():
		return default

	var res = output[idx]
	if not res is Array:
		res = [res]
	if res.size() == 0:
		return default

	# If the output is a node array, we need to duplicate them first otherwise they get passed as
	# references which causes issues when the same output is sent to two different nodes.
	if res[0] is Node:
		var duplicates = []
		for i in res.size():
			var node = res[i].duplicate(7)
			register_to_garbage_collection(node)
			duplicates.append(node)
		return duplicates

	# If it's not a node array, it's made of built in types (scalars, vectors ...) which are passed
	# as copy by default.
	return res


"""
Query the parent ConceptGraph node in the editor and returns the corresponding input node if it
exists
"""
func get_editor_input(name: String) -> Node:
	var parent = get_parent()
	if not parent:
		return null
	var input = parent.concept_graph.get_input(name)
	if not input:
		return null

	var input_copy = input.duplicate(7)
	register_to_garbage_collection(input_copy)
	return input_copy


"""
Return the variables exposed to the node inspector. Same format as get_property_list
[ {name: , type: }, ... ]
"""
func get_exposed_variables() -> Array:
	return []


func get_concept_graph():
	return get_parent().concept_graph


"""
Clears the cache and the cache of every single nodes right to this one.
"""
func reset() -> void:
	clear_cache()
	for node in get_parent().get_all_right_nodes(self):
		node.reset()


func clear_cache() -> void:
	_clear_cache()
	_reset_output()
	_output_ready = false


func export_editor_data() -> Dictionary:
	var editor_scale = ConceptGraphEditorUtil.get_dpi_scale()
	var data = {}
	data["offset_x"] = offset.x / editor_scale
	data["offset_y"] = offset.y / editor_scale

	if resizable:
		data["rect_x"] = rect_size.x
		data["rect_y"] = rect_size.y

	if not _dynamic_inputs.empty():
		data["dynamic_inputs"] = _dynamic_inputs["count"]

	data["slots"] = {}
	var slots = _hboxes.size()
	for i in slots:
		var idx = String(i) # Needed to fix inconsistencies when calling restore
		var hbox = _hboxes[i]
		for c in hbox.get_children():
			if c is CheckBox:
				data["slots"][idx] = c.pressed
			if c is SpinBox:
				data["slots"][idx] = c.value
			if c is LineEdit:
				data["slots"][idx] = c.text
			if c is OptionButton:
				data["slots"][idx] = c.get_item_id(c.selected)

	return data


func restore_editor_data(data: Dictionary) -> void:
	var editor_scale = ConceptGraphEditorUtil.get_dpi_scale()
	offset.x = data["offset_x"] * editor_scale
	offset.y = data["offset_y"] * editor_scale

	if data.has("rect_x"):
		rect_size.x = data["rect_x"]
	if data.has("rect_y"):
		rect_size.y = data["rect_y"]
	emit_signal("resize_request", rect_size)

	if has_custom_gui():
		return

	# Recreate all slots before trying to restore their data but only it this is called from
	# load template, not from regenerate_default_gui
	if data.has("dynamic_inputs") and _dynamic_inputs["count"] == 0:
		_dynamic_inputs["count"] = data["dynamic_inputs"]
		for i in data["dynamic_inputs"]:
			set_input(_inputs.size(), _dynamic_inputs["name"], _dynamic_inputs["type"], _dynamic_inputs["opts"])
		_generate_default_gui()

	var slots = _hboxes.size()

	for i in slots:
		if data["slots"].has(String(i)):
			var type = _inputs[i]["type"]
			var value = data["slots"][String(i)]
			var hbox = _hboxes[i]

			match type:
				ConceptGraphDataType.BOOLEAN:
					hbox.get_node("CheckBox").pressed = value
				ConceptGraphDataType.SCALAR:
					hbox.get_node("SpinBox").value = value
				ConceptGraphDataType.STRING:
					if hbox.has_node("LineEdit"):
						hbox.get_node("LineEdit").text = value
					elif hbox.has_node("OptionButton"):
						var btn: OptionButton = hbox.get_node("OptionButton")
						btn.selected = btn.get_item_index(value)


"""
Because we're saving the tree to a json file, we need each node to explicitely specify the data
to save. It's also the node responsability to restore it when we load the file. Most nodes
won't need this but it could be useful for nodes that allows the user to type in raw values
directly if nothing is connected to a slot.
"""
func export_custom_data() -> Dictionary:
	return {}


"""
This method get exactly what it exported from the export_custom_data method. Use it to manually
restore the previous node state.
"""
func restore_custom_data(_data: Dictionary) -> void:
	pass


func is_input_connected(idx: int) -> bool:
	var parent = get_parent()
	if not parent:
		return false

	return parent.is_node_connected_to_input(self, idx)


func set_input(idx: int, name: String, type: int, opts: Dictionary = {}) -> void:
	_inputs[idx] = {
		"name": name,
		"type": type,
		"options": opts,
		"mirror": []
	}


func set_output(idx: int, name: String, type: int, opts: Dictionary = {}) -> void:
	_outputs[idx] = {
		"name": name,
		"type": type,
		"options": opts
	}


func remove_input(idx: int) -> bool:
	if not _inputs.erase(idx):
		return false

	if is_input_connected(idx):
		get_parent()._disconnect_input(self, idx)

	return true


func mirror_slots_type(input_index, output_index) -> void:
	if input_index >= _inputs.size():
		print("Error: invalid input index passed to mirror_slots_type ", input_index)
		return

	if output_index >= _outputs.size():
		print("Error: invalid output index passed to mirror_slots_type ", output_index)
		return

	_inputs[input_index]["mirror"].append(output_index)
	_inputs[input_index]["default_type"] = _inputs[input_index]["type"]


"""
Dynamic inputs are inputs the user can create on the fly from the graph editor. Pressing a button
creates or removes an input. They all share the same type, name and options.
"""
func enable_dynamic_inputs(input_name: String, type, options := {}) -> void:
	_dynamic_inputs = {}
	_dynamic_inputs["count"] = 0
	_dynamic_inputs["type"] = type
	_dynamic_inputs["name"] = input_name
	_dynamic_inputs["opts"] = options


"""
Override the default gui value with a new one. // TODO : might not be useful, could be removed if not used
"""
func set_default_gui_input_value(idx: int, value) -> void:
	if _hboxes.size() <= idx:
		return

	var hbox = _hboxes[idx]
	var type = _inputs[idx]["type"]
	match type:
		ConceptGraphDataType.BOOLEAN:
			hbox.get_node("CheckBox").pressed = value
		ConceptGraphDataType.SCALAR:
			hbox.get_node("SpinBox").value = value
		ConceptGraphDataType.STRING:
			hbox.get_node("LineEdit").text = value


"""
Override this method when exposing a variable to the inspector. It's up to you to decide what to
do with the user defined value.
"""
func set_value_from_inspector(_name: String, _value) -> void:
	pass


func register_to_garbage_collection(resource):
	get_parent().register_to_garbage_collection(resource)


"""
Force the node to rebuild the user interface. This is needed because the Node is generated under
a spatial, which make accessing the current theme impossible and breaks OptionButtons.
"""
func regenerate_default_ui():
	if has_custom_gui():
		return

	var editor_data = export_editor_data()
	var custom_data = export_custom_data()
	_generate_default_gui()
	restore_editor_data(editor_data)
	restore_custom_data(custom_data)
	_setup_slots()


"""
Returns a list of every ConceptNode connected to this node
"""
func _get_connected_inputs() -> Array:
	var connected_inputs = []
	for i in _inputs.size():
		var info = get_parent().get_left_node(self, i)
		if info.has("node"):
			connected_inputs.append(info["node"])
	return connected_inputs


"""
Loops through all connected input nodes and request them to prepare their output. Each output
then signals this node when they finished their task. When all the inputs are ready, signals this
node that the generation can begin.
Returns true if all inputs are already ready.
"""
func _request_inputs_to_get_ready() -> bool:
	var connected_inputs = _get_connected_inputs()

	# No connected nodes, inputs data are available locally
	if connected_inputs.size() == 0:
		return true

	# Call prepare_output on every connected inputs
	for input_node in connected_inputs:
		if not input_node.is_connected("output_ready", self, "_on_input_ready"):
			input_node.connect("output_ready", self, "_on_input_ready")
		input_node.call_deferred("prepare_output")
	return false


"""
This function is ran in the background from prepare_output(). Emits a signal when the outputs
are ready.
"""
func _run_background_generation() -> void:
	_generate_outputs()
	_output_ready = true
	_generation_requested = false
	call_deferred("emit_signal", "output_ready")


"""
Overide this function in the derived classes to return something usable.
Generate all the outputs for every output slots declared.
"""
func _generate_outputs() -> void:
	pass


"""
Override this if you're using a custom GUI to change input slots default behavior. This returns
the local input data for the given slot
"""
func _get_input(_index: int) -> Array:
	return []


"""
Overide this function to customize how the output cache should be cleared. If you have memory
to free or anything else, that's where you should define it.
"""
func _clear_cache():
	pass


"""
Clear previous outputs and create as many empty arrays as there are output slots in the graph node.
"""
func _reset_output():
	for slot in output:
		if slot is Array:
			for res in slot:
				if res is Node:
					res.queue_free()
		elif slot is Node:
			slot.queue_free()

	output = []
	for i in _outputs.size():
		output.append([])


"""
Based on the previous calls to set_input and set_ouput, this method will call the
GraphNode.set_slot method accordingly with the proper parameters. This makes it easier syntax
wise on the child node side and make it more readable.
"""
func _setup_slots() -> void:
	var slots = _hboxes.size()
	for i in slots + 1:	# +1 to prevent leaving an extra slot active when removing dynamic inputs
		var has_input = false
		var input_type = 0
		var input_color = Color(0)
		var has_output = false
		var output_type = 0
		var output_color = Color(0)

		if _inputs.has(i):
			has_input = true
			input_type = _inputs[i]["type"]
			input_color = ConceptGraphDataType.COLORS[input_type]
		if _outputs.has(i):
			has_output = true
			output_type = _outputs[i]["type"]
			output_color = ConceptGraphDataType.COLORS[output_type]

		if not has_input and not has_output and i < _hboxes.size():
			_hboxes[i].visible = false

		set_slot(i, has_input, input_type, input_color, has_output, output_type, output_color)

	# Remove elements generated as part of the default gui but doesn't match any slots
	for b in _hboxes:
		if not b.visible:
			print("erased ", b)
			_hboxes.erase(b)
			remove_child(b)

	# If the node can't be resized, make it as small as possible
	if not resizable:
		emit_signal("resize_request", Vector2.ZERO)


"""
Clear all child controls
"""
func _clear_gui() -> void:
	_hboxes = []
	for child in get_children():
		if child is Control:
			remove_child(child)
			child.queue_free()


"""
Based on graph node category this method will setup corresponding style and color of graph node
"""
func _generate_default_gui_style() -> void:
	# Base Style
	var style = StyleBoxFlat.new()
	var color = Color(0.121569, 0.145098, 0.192157, 0.9)
	style.border_color = ConceptGraphDataType.to_category_color(category)
	style.set_bg_color(color)
	style.set_border_width_all(2)
	style.set_border_width(MARGIN_TOP, 32)
	style.content_margin_left = 24;
	style.content_margin_right = 24;
	style.set_corner_radius_all(4)
	style.set_expand_margin_all(4)
	style.shadow_size = 8
	style.shadow_color = Color(0,0,0,0.2)
	add_stylebox_override("frame", style)

	# Selected Style
	var selected_style = style.duplicate()
	selected_style.shadow_color = ConceptGraphDataType.to_category_color(category)
	selected_style.shadow_size = 4
	selected_style.border_color = Color(0.121569, 0.145098, 0.192157, 0.9)
	add_stylebox_override("selectedframe", selected_style)
	add_constant_override("port_offset", 12)
	add_font_override("title_font", get_font("bold", "EditorFonts"))


"""
If the child node does not define a custom UI itself, this function will generate a default UI
based on the parameters provided with set_input and set_ouput. Each slots will have a Label
and their name attached.
The input slots will have additional UI elements based on their type.
Scalars input gets a spinbox that's hidden when something is connected to the slot.
Values stored in the spinboxes are automatically exported and restored.
"""
func _generate_default_gui() -> void:
	if has_custom_gui():
		return

	_clear_gui()
	_generate_default_gui_style()

	title = display_name
	resizable = false
	show_close = true
	rect_min_size = Vector2(0.0, 0.0)
	rect_size = Vector2(0.0, 0.0)

	# TODO : Some refactoring would be nice
	var slots = max(_inputs.size(), _outputs.size())
	for i in slots:
		# Create a Hbox container per slot like this -> [LabelIn, (opt), LabelOut]
		var hbox = HBoxContainer.new()
		hbox.rect_min_size.y = 24

		# Make sure it appears in the editor and store along the other Hboxes
		_hboxes.append(hbox)
		add_child(hbox)

		# label_left holds the name of the input slot.
		var label_left = Label.new()
		label_left.name = "LabelLeft"
		label_left.mouse_filter = MOUSE_FILTER_PASS
		hbox.add_child(label_left)

		# If this slot has an input
		if _inputs.has(i):
			label_left.text = _inputs[i]["name"]
			label_left.hint_tooltip = ConceptGraphDataType.Types.keys()[_inputs[i]["type"]].capitalize()

			# Add the optional UI elements based on the data type.
			# TODO : We could probably just check if the property exists with get_property_list
			# and to that automatically instead of manually setting everything one by one
			match _inputs[i]["type"]:
				ConceptGraphDataType.BOOLEAN:
					var opts = _inputs[i]["options"]
					var checkbox = CheckBox.new()
					checkbox.name = "CheckBox"
					checkbox.pressed = opts["value"] if opts.has("value") else false
					checkbox.connect("toggled", self, "_on_default_gui_value_changed", [i])
					checkbox.connect("toggled", self, "_on_default_gui_interaction", [checkbox, i])
					hbox.add_child(checkbox)
				ConceptGraphDataType.SCALAR:
					var opts = _inputs[i]["options"]
					var spinbox = SpinBox.new()
					spinbox.name = "SpinBox"
					spinbox.max_value = opts["max"] if opts.has("max") else 1000
					spinbox.min_value = opts["min"] if opts.has("min") else 0
					spinbox.value = opts["value"] if opts.has("value") else 0
					spinbox.step = opts["step"] if opts.has("step") else 0.001
					spinbox.exp_edit = opts["exp"] if opts.has("exp") else true
					spinbox.allow_greater = opts["allow_greater"] if opts.has("allow_greater") else true
					spinbox.allow_lesser = opts["allow_lesser"] if opts.has("allow_lesser") else false
					spinbox.rounded = opts["rounded"] if opts.has("rounded") else false
					spinbox.connect("value_changed", self, "_on_default_gui_value_changed", [i])
					spinbox.connect("value_changed", self, "_on_default_gui_interaction", [spinbox, i])
					hbox.add_child(spinbox)
				ConceptGraphDataType.STRING:
					var opts = _inputs[i]["options"]
					if opts.has("type") and opts["type"] == "dropdown":
						var dropdown = OptionButton.new()
						dropdown.name = "OptionButton"
						for item in opts["items"].keys():
							dropdown.add_item(item, opts["items"][item])
						dropdown.connect("item_selected", self, "_on_default_gui_value_changed", [i])
						dropdown.connect("item_selected", self, "_on_default_gui_interaction", [dropdown, i])
						hbox.add_child(dropdown)
					else:
						var line_edit = LineEdit.new()
						line_edit.name = "LineEdit"
						line_edit.placeholder_text = opts["placeholder"] if opts.has("placeholder") else "Text"
						line_edit.expand_to_text_length = opts["expand"] if opts.has("expand") else true
						line_edit.connect("text_changed", self, "_on_default_gui_value_changed", [i])
						line_edit.connect("text_changed", self, "_on_default_gui_interaction", [line_edit, i])
						hbox.add_child(line_edit)

		# Label right holds the output slot name. Set to expand and align_right to push the text on
		# the right side of the node panel
		var label_right = Label.new()
		label_right.name = "LabelRight"
		label_right.mouse_filter = MOUSE_FILTER_PASS
		label_right.size_flags_horizontal = SIZE_EXPAND_FILL
		label_right.align = Label.ALIGN_RIGHT

		if _outputs.has(i):
			label_right.text = _outputs[i]["name"]
			label_right.hint_tooltip = ConceptGraphDataType.Types.keys()[_outputs[i]["type"]].capitalize()
		hbox.add_child(label_right)

	if not _dynamic_inputs.empty():
		_setup_dynamic_input_controls()

	_on_connection_changed()
	_on_default_gui_ready()
	_redraw()


"""
Creates two buttons to create or remove inputs on the fly
"""
func _setup_dynamic_input_controls() -> void:
	if not _dynamic_inputs:
		return

	var add = _make_button("+")
	var remove = _make_button("-")
	add.connect("pressed", self, "_create_new_input_slot")
	remove.connect("pressed", self, "_delete_last_input_slot")

	_btn_container = HBoxContainer.new()
	_btn_container.alignment = BoxContainer.ALIGN_END
	_btn_container.add_child(add)
	_btn_container.add_child(remove)

	add_child(_btn_container)


"""
Create a generic button with the given text
"""
func _make_button(text: String) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.rect_min_size.y = 24
	return btn


func _create_new_input_slot() -> void:
	_dynamic_inputs["count"] += 1
	var index = _inputs.size()
	set_input(index, _dynamic_inputs["name"], _dynamic_inputs["type"], _dynamic_inputs["opts"])
	regenerate_default_ui()
	emit_signal("node_changed", self, true)


func _delete_last_input_slot() -> void:
	if _dynamic_inputs["count"] <= 0:
		return

	if remove_input(_inputs.size() - 1):
		_dynamic_inputs["count"] -= 1
		regenerate_default_ui()
		emit_signal("node_changed", self, true)


"""
Forces the GraphNode to redraw its gui, mostly to get rid of outdated connections after a delete.
"""
func _redraw() -> void:
	hide()
	show()


func _connect_signals() -> void:
	connect("close_request", self, "_on_close_request")
	connect("resize_request", self, "_on_resize_request")
	connect("connection_changed", self, "_on_connection_changed")
	_resize_timer.connect("timeout", self, "_on_resize_timeout")


"""
Called when a connected input node has finished generating its output data. This method checks
if every other connected node has completed their task. If they are ready, notify this node to
resume its output generation
"""
func _on_input_ready() -> void:
	var all_inputs_ready := true
	var connected_inputs := _get_connected_inputs()
	for input_node in connected_inputs:
		if not input_node.is_output_ready():
			all_inputs_ready = false

	if all_inputs_ready:
		emit_signal("all_inputs_ready")


func _on_resize_request(new_size) -> void:
	rect_size = new_size
	_resize_timer.start(2.0)


func _on_resize_timeout() -> void:
	emit_signal("node_changed", self, false)


func _on_close_request() -> void:
	emit_signal("delete_node", self)


"""
When the nodes connections changes, this method checks for all the input slots and hides
everything that's not a label if something is connected to the associated slot.
"""
func _on_connection_changed() -> void:
	# Hides the default gui (except for the labels) if a connection is present for the given slot
	for i in _hboxes.size():
		for ui in _hboxes[i].get_children():
			if not ui is Label:
				ui.visible = !is_input_connected(i)

	# Change the slots type if the mirror option is enabled
	var slots_types_updated = false
	var count = _inputs.size()
	if not _dynamic_inputs.empty():
		count -= _dynamic_inputs["count"]

	for i in count:
		for o in _inputs[i]["mirror"]:
			slots_types_updated = true
			var type = _inputs[i]["default_type"]
			# Copy the connected input type if there is one
			if is_input_connected(i):
				var data = get_parent().get_left_node(self, i)
				type = data["node"]._outputs[data["slot"]]["type"]

			_inputs[i]["type"] = type
			_outputs[o]["type"] = type

	if slots_types_updated:
		_setup_slots()

	_redraw()


"""
Override this function if you have custom gui to create on top of the default one
"""
func _on_default_gui_ready():
	pass


func _on_default_gui_value_changed(value, slot: int) -> void:
	emit_signal("node_changed", self, true)
	emit_signal("input_changed", slot, value)
	reset()


func _on_default_gui_interaction(_value, _control: Control, _slot: int) -> void:
	pass
