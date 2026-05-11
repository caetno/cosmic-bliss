#include "marionette_core.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

String MarionetteCore::hello() const {
	return String("marionette_core ok");
}

void MarionetteCore::tick(double p_delta) {
	(void)p_delta;
}

void MarionetteCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("hello"), &MarionetteCore::hello);
	ClassDB::bind_method(D_METHOD("tick", "delta"), &MarionetteCore::tick);
}

} // namespace godot
