#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "procedural/procedural_kernels.h"
#include "solver/pbd_solver.h"
#include "solver/tentacle.h"
#include "spline/catmull_spline.h"
#include "spline/spline_data_packer.h"

using namespace godot;

void initialize_tentacletech_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	GDREGISTER_CLASS(CatmullSpline);
	GDREGISTER_CLASS(SplineDataPacker);
	GDREGISTER_CLASS(PBDSolver);
	GDREGISTER_CLASS(Tentacle);
	GDREGISTER_CLASS(ProceduralKernels);
}

void uninitialize_tentacletech_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT tentacletech_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_tentacletech_module);
	init_obj.register_terminator(uninitialize_tentacletech_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
