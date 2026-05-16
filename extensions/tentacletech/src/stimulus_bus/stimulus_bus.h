#ifndef TENTACLETECH_STIMULUS_BUS_H
#define TENTACLETECH_STIMULUS_BUS_H

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <unordered_map>
#include <vector>

// Phase 6 — Stimulus Bus (minimum slice).
//
// Spec: docs/architecture/TentacleTech_Architecture.md §8.
//
// This slice ships the bus contract — event ring buffer + continuous
// channels keyed by orifice ObjectID — and wires the 5 minimum emission
// sites listed in the §4 slice 7 of the 2026-05-14-03 ragdoll-under-
// tension scenario amendment:
//   - PenetrationStart    (event, fired at EI creation)
//   - RingTransitStart    (event, stubbed at EI creation in 6-min;
//                          per-rim-particle transit tracking deferred)
//   - KnotEngulfed        (event, stubbed pending girth_gradient_at_rim)
//   - GripEngaged         (continuous channel, updated each tick on the
//                          orifice's grip_engagement)
//   - OrificeDamaged      (continuous channel, damage_rate; stubbed
//                          when no clean damage-rate signal is available)
//
// Subscribers (Sonance, Reverie) are not wired in this slice — the value
// is the seam, not the consumer.

class StimulusBus : public godot::Object {
	GDCLASS(StimulusBus, godot::Object)

public:
	// §8.1 verbatim. EVENT_TYPE_COUNT is an impl sentinel — not in the
	// spec, used internally for bound-checked filters.
	enum StimulusEventType {
		EVENT_PenetrationStart = 0,
		EVENT_PenetrationEnd,
		EVENT_BulbPop,
		EVENT_StickSlipBreak,
		EVENT_GripEngaged,
		EVENT_GripBroke,
		EVENT_RingOverstretched,
		EVENT_HardStopBottomedOut,
		EVENT_FluidSeparation,
		EVENT_WetSeparation,
		EVENT_Impact,
		EVENT_TangentialSlap,
		EVENT_SkinPressure,
		EVENT_OrificeDamaged,
		EVENT_TentacleTangled,
		EVENT_EnvironmentalFlash,
		EVENT_LoudSound,
		EVENT_TemperatureDrop,
		EVENT_DialogueAddressed,
		EVENT_ObserverArrived,
		EVENT_RunStarted,
		EVENT_RunEnded,
		EVENT_PayloadDeposited,
		EVENT_PayloadExpelled,
		EVENT_StorageBeadMigrated,
		EVENT_RingTransitStart,
		EVENT_RingTransitEnd,
		EVENT_PhenomenonAchieved,
		EVENT_OrgasmStart,
		EVENT_OrgasmEnd,
		EVENT_GagReflexStart,
		EVENT_GagReflexEnd,
		EVENT_PainExpulsionStart,
		EVENT_PainExpulsionEnd,
		EVENT_RefusalSpasmStart,
		EVENT_RefusalSpasmEnd,
		EVENT_ContractionPulseFired,
		EVENT_KnotEngulfed,
		EVENT_EntryRejected,
		EVENT_TYPE_COUNT,
	};

	// Ring-buffer capacity. ~2s TTL at 60 Hz physics + spare for
	// burstier emitters. §8.1 says "256 entries default".
	static constexpr int RING_BUFFER_CAPACITY = 256;

	struct StimulusEvent {
		int type = 0;
		float magnitude = 0.0f;
		float raw_value = 0.0f;
		godot::Vector3 world_position;
		int body_area_id = 0;
		int source_id = 0;
		int target_id = 0;
		float timestamp = 0.0f;
		godot::Dictionary extra;
	};

	StimulusBus();
	~StimulusBus();

	// Singleton accessor — set at autoload time, accessed from physics
	// code via `StimulusBus::get_singleton()`. Returns nullptr if no
	// autoload registered yet (tests can set it directly).
	static StimulusBus *get_singleton();
	static void set_singleton(StimulusBus *p_bus);

	// Install / uninstall — used by the GDScript autoload to flip the
	// static singleton pointer. Exposed to bindings so the autoload
	// wrapper can call them.
	void install_as_singleton();
	void uninstall_as_singleton();

	// Emit an event. Pushes onto the ring buffer; oldest entries
	// overwritten when capacity is exceeded. Timestamp is filled from
	// the monotonic clock at call time.
	void emit(int type, float magnitude, float raw_value,
			const godot::Vector3 &world_position, int body_area_id,
			int source_id, int target_id, const godot::Dictionary &extra);

	// Convenience: emit with auto-timestamp and a single Dictionary
	// payload. `type` is the only required field; other slots default
	// to zero / origin / -1 / empty.
	void emit_simple(int type, const godot::Dictionary &payload);

	// Query the ring buffer. `time_window` in seconds — events whose
	// timestamp falls within `[now - time_window, now]` are returned
	// by copy (snapshot pattern §15). `type_filter < 0` returns all
	// types; else only matching events.
	godot::Array get_recent_events(float time_window, int type_filter = -1) const;

	int get_event_count() const;
	int get_capacity() const;

	// Continuous channels — keyed by orifice ObjectID. Each orifice
	// owns a small Dictionary with the §8.1 (line 1723-1726) fields
	// plus `damage_rate` (added 2026-05-14 for OrificeDamaged-continuous).
	void set_orifice_state_field(int64_t orifice_id, const godot::StringName &field, float value);
	float get_orifice_state_field(int64_t orifice_id, const godot::StringName &field) const;
	godot::Dictionary get_orifice_state_snapshot(int64_t orifice_id) const;

	// Lifecycle helpers — useful for tests + clean shutdown.
	void clear();

	// Test-only: advance the monotonic clock by an arbitrary delta.
	// In production the clock comes from `Time.get_ticks_usec()`; tests
	// override via this setter to exercise time-window filtering without
	// real-time waits. Negative deltas allowed (re-emit past events).
	void test_advance_clock(float seconds);

protected:
	static void _bind_methods();

private:
	static StimulusBus *_singleton;

	// Ring buffer — `_events_head` is the next write slot; the buffer
	// is `RING_BUFFER_CAPACITY`-sized and zero-initialized. `_event_count`
	// caps at capacity for the snapshot query.
	std::vector<StimulusEvent> _events;
	int _events_head = 0;
	int _event_count = 0;

	// Continuous channels. Outer key = orifice ObjectID. Inner
	// dictionary holds the §8.1 fields as floats.
	std::unordered_map<int64_t, godot::Dictionary> _orifice_state;

	// Monotonic clock — initialized in ctor; `_clock_offset_seconds` is
	// the test-injected shift added to the real clock when computing
	// `_now()`.
	float _clock_base_seconds = 0.0f;
	float _clock_offset_seconds = 0.0f;
	float _now() const;
};

// VARIANT_ENUM_CAST is invoked in stimulus_bus.cpp after class_db.hpp
// is included — needed because the macro references GetTypeInfo<>.

#endif // TENTACLETECH_STIMULUS_BUS_H
