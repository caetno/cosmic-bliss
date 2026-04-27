#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {
class RenderingDevice;
}

// Phase 0 stand-in for the full Codename Udon particle system. Owns a single
// compute dispatch that writes a test pattern into an RD storage image,
// exposed as a Texture2DRD for sampling from a regular ShaderMaterial.
//
// Every RID-touching call routes through RenderingServer.call_on_render_thread
// per the project's render-thread discipline.
class UdonParticleSystem : public godot::Node3D {
    GDCLASS(UdonParticleSystem, godot::Node3D);

public:
    UdonParticleSystem();
    ~UdonParticleSystem();

    void _ready() override;
    void _process(double p_delta) override;
    void _exit_tree() override;

    void set_texture_size(int p_size);
    int get_texture_size() const;

    void set_shader_path(const godot::String &p_path);
    godot::String get_shader_path() const;

    godot::Ref<godot::Texture2DRD> get_output_texture() const;

protected:
    static void _bind_methods();

private:
    int texture_size = 256;
    godot::String shader_path = "res://addons/tenticles/shaders/sim/hello_world.glsl";

    godot::Ref<godot::Texture2DRD> output_texture;
    float elapsed = 0.0f;

    // Touched only on the render thread once `_ready` has fired its
    // initialization closure; main thread reads `output_texture` indirectly
    // via the deferred `_apply_texture_to_resource` callback.
    bool rd_initialized = false;
    godot::String compute_source;
    godot::RID texture_rid;
    godot::RID shader_rid;
    godot::RID pipeline_rid;
    godot::RID uniform_set_rid;

    void _rd_initialize();
    void _rd_dispatch(float p_time);
    void _rd_release();
    void _apply_texture_to_resource();
};
