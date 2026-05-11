#ifndef MARIONETTE_CORE_H
#define MARIONETTE_CORE_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// Phase 2.0 scaffold: proves the GDScript -> C++ bridge.
// Real composer/SPD/IK populate this class in later phases.
class MarionetteCore : public Node {
	GDCLASS(MarionetteCore, Node)

public:
	MarionetteCore() = default;
	~MarionetteCore() = default;

	String hello() const;
	void tick(double p_delta);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // MARIONETTE_CORE_H
