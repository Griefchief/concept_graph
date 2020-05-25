tool
extends ConceptNode


func _init() -> void:
	unique_id = "duplicate_nodes_for_each_source_node"
	display_name = "Spawn Duplicates For Each Source Node"
	category = "Nodes/Instancers"
	description = "Spawns multiple copies of an array of nodes offseted by the given positions"

	set_input(0, "Source", ConceptGraphDataType.NODE_3D)
	set_input(1, "Transforms", ConceptGraphDataType.NODE_3D)
	set_output(0, "Duplicates", ConceptGraphDataType.NODE_3D)

	mirror_slots_type(0, 0)


func _generate_outputs() -> void:
	var sources = get_input(0)
	var transforms := get_input(1)

	if not sources or sources.size() == 0 or not transforms or transforms.size() == 0:
		return
	
	var s_num = 0
	for s in sources:
		for t in transforms:
			var t_num = 0
			var n = s.duplicate() as Spatial
			#n.global_transform = t.transform
			n.transform.origin = s.transform.origin+t.transform.origin
			
			output[0].append(n)
			t_num+=1
		s_num+=1
