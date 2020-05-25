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
	var sources = get_input_single(0)
	var transforms := get_input(1)

	print ("spawn_arrays: generating outputs")
	if not sources or sources.size() == 0 or not transforms or transforms.size() == 0:
		return
	
	print ("spawn_arrays: exists sources ", sources, " size ", sources.size(), " transforms ",transforms, " size ",transforms.size())
	var s_num = 0
	var t_num = 0
	for s in sources:
		for t in transforms:
			var n = s.duplicate() as Spatial
			#n.global_transform = t.transform
			n.global_transform.origin = n.global_transform.origin+t.transform.origin
			print ("duplicating s_num ",s_num, " t_num", t_num, " at ", n.global_transform.origin, " from s ",n.global_transform.origin, " and t ",t.transform.origin)
			
			output[0].append(n)
			
