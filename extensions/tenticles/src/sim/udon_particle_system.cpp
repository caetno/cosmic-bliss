#include "sim/udon_particle_system.h"

#include "util/udon_log.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cstring>

using namespace godot;

UdonParticleSystem::UdonParticleSystem() {
    output_texture.instantiate();
}

UdonParticleSystem::~UdonParticleSystem() = default;

void UdonParticleSystem::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_texture_size", "size"), &UdonParticleSystem::set_texture_size);
    ClassDB::bind_method(D_METHOD("get_texture_size"), &UdonParticleSystem::get_texture_size);
    ClassDB::bind_method(D_METHOD("set_shader_path", "path"), &UdonParticleSystem::set_shader_path);
    ClassDB::bind_method(D_METHOD("get_shader_path"), &UdonParticleSystem::get_shader_path);
    ClassDB::bind_method(D_METHOD("get_output_texture"), &UdonParticleSystem::get_output_texture);

    ClassDB::add_property("UdonParticleSystem",
        PropertyInfo(Variant::INT, "texture_size", PROPERTY_HINT_RANGE, "16,4096,1"),
        "set_texture_size", "get_texture_size");
    ClassDB::add_property("UdonParticleSystem",
        PropertyInfo(Variant::STRING, "shader_path", PROPERTY_HINT_FILE, "*.glsl"),
        "set_shader_path", "get_shader_path");
}

void UdonParticleSystem::set_texture_size(int p_size) {
    texture_size = p_size < 16 ? 16 : p_size;
}

int UdonParticleSystem::get_texture_size() const {
    return texture_size;
}

void UdonParticleSystem::set_shader_path(const String &p_path) {
    shader_path = p_path;
}

String UdonParticleSystem::get_shader_path() const {
    return shader_path;
}

Ref<Texture2DRD> UdonParticleSystem::get_output_texture() const {
    return output_texture;
}

void UdonParticleSystem::_ready() {
    Ref<FileAccess> f = FileAccess::open(shader_path, FileAccess::READ);
    if (f.is_null()) {
        udon::log::error("could not open compute shader: " + shader_path);
        return;
    }
    compute_source = f->get_as_text();
    f->close();

    set_process(true);

    RenderingServer::get_singleton()->call_on_render_thread(
        callable_mp(this, &UdonParticleSystem::_rd_initialize));
}

void UdonParticleSystem::_process(double p_delta) {
    if (compute_source.is_empty()) return;
    elapsed += static_cast<float>(p_delta);

    RenderingServer::get_singleton()->call_on_render_thread(
        callable_mp(this, &UdonParticleSystem::_rd_dispatch).bind(elapsed));
}

void UdonParticleSystem::_exit_tree() {
    if (!rd_initialized) return;
    RenderingServer::get_singleton()->call_on_render_thread(
        callable_mp(this, &UdonParticleSystem::_rd_release));
}

// ---- render-thread methods ---------------------------------------------------

void UdonParticleSystem::_rd_initialize() {
    if (rd_initialized) return;

    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    if (rd == nullptr) {
        udon::log::error("no RenderingDevice (headless server build?); particle system disabled");
        return;
    }

    // 1. Compile the GLSL 450 source into SPIR-V via RDShaderSource. Pure
    //    GLSL (no Godot #[compute] wrapper); see CLAUDE.md.
    Ref<RDShaderSource> src;
    src.instantiate();
    src->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
    src->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, compute_source);

    Ref<RDShaderSPIRV> spirv = rd->shader_compile_spirv_from_source(src);
    if (spirv.is_null()) {
        udon::log::error("shader_compile_spirv_from_source returned null");
        return;
    }
    String compile_err = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE);
    if (!compile_err.is_empty()) {
        udon::log::error("compute shader compile error: " + compile_err);
        return;
    }

    shader_rid = rd->shader_create_from_spirv(spirv, "tenticles.hello_world");
    if (!shader_rid.is_valid()) {
        udon::log::error("shader_create_from_spirv failed");
        return;
    }

    pipeline_rid = rd->compute_pipeline_create(shader_rid);
    if (!pipeline_rid.is_valid()) {
        udon::log::error("compute_pipeline_create failed");
        return;
    }

    // 2. Create the storage image the compute shader will write to. RGBA8
    //    UNORM is enough for a hello-world test pattern; promote to RGBA16F
    //    once particle attributes are packed in here in Phase 1.
    Ref<RDTextureFormat> fmt;
    fmt.instantiate();
    fmt->set_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM);
    fmt->set_width(static_cast<uint32_t>(texture_size));
    fmt->set_height(static_cast<uint32_t>(texture_size));
    fmt->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
    fmt->set_usage_bits(
        RenderingDevice::TEXTURE_USAGE_STORAGE_BIT |
        RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
        RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
        RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);

    Ref<RDTextureView> view;
    view.instantiate();

    texture_rid = rd->texture_create(fmt, view, TypedArray<PackedByteArray>());
    if (!texture_rid.is_valid()) {
        udon::log::error("texture_create failed");
        return;
    }

    // 3. Wire the storage image into uniform set 0 binding 0.
    Ref<RDUniform> u_image;
    u_image.instantiate();
    u_image->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
    u_image->set_binding(0);
    u_image->add_id(texture_rid);

    TypedArray<RDUniform> uniforms;
    uniforms.push_back(u_image);

    uniform_set_rid = rd->uniform_set_create(uniforms, shader_rid, 0);
    if (!uniform_set_rid.is_valid()) {
        udon::log::error("uniform_set_create failed");
        return;
    }

    rd_initialized = true;
    udon::log::info("Phase 0 hello-world initialized (" +
        String::num_int64(texture_size) + "x" + String::num_int64(texture_size) + ")");

    // 4. Hand the RID to the Texture2DRD wrapper from the main thread. The
    //    Resource's emit_changed inside set_texture_rd_rid is not safe to fire
    //    from the render thread, so bounce through call_deferred.
    callable_mp(this, &UdonParticleSystem::_apply_texture_to_resource).call_deferred();
}

void UdonParticleSystem::_rd_dispatch(float p_time) {
    if (!rd_initialized) return;

    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    if (rd == nullptr) return;

    // Push constant: 16 bytes (Vulkan minimum alignment is 16, layout(std430)).
    PackedByteArray pc;
    pc.resize(16);
    uint8_t *w = pc.ptrw();
    std::memcpy(w + 0, &p_time, sizeof(float));
    float zero = 0.0f;
    std::memcpy(w + 4, &zero, sizeof(float));
    std::memcpy(w + 8, &zero, sizeof(float));
    std::memcpy(w + 12, &zero, sizeof(float));

    const uint32_t group_size = 8;
    const uint32_t groups = (static_cast<uint32_t>(texture_size) + group_size - 1) / group_size;

    int64_t cl = rd->compute_list_begin();
    rd->compute_list_bind_compute_pipeline(cl, pipeline_rid);
    rd->compute_list_bind_uniform_set(cl, uniform_set_rid, 0);
    rd->compute_list_set_push_constant(cl, pc, static_cast<uint32_t>(pc.size()));
    rd->compute_list_dispatch(cl, groups, groups, 1);
    rd->compute_list_end();
}

void UdonParticleSystem::_rd_release() {
    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    if (rd == nullptr) return;

    // Free in reverse-dependency order. uniform_set references both texture
    // and shader, so it goes first.
    if (uniform_set_rid.is_valid()) { rd->free_rid(uniform_set_rid); uniform_set_rid = RID(); }
    if (pipeline_rid.is_valid())    { rd->free_rid(pipeline_rid);    pipeline_rid = RID(); }
    if (texture_rid.is_valid())     { rd->free_rid(texture_rid);     texture_rid = RID(); }
    if (shader_rid.is_valid())      { rd->free_rid(shader_rid);      shader_rid = RID(); }
    rd_initialized = false;
}

void UdonParticleSystem::_apply_texture_to_resource() {
    if (output_texture.is_valid() && texture_rid.is_valid()) {
        output_texture->set_texture_rd_rid(texture_rid);
    }
}
