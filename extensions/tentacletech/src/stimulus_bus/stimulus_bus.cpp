#include "stimulus_bus.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/variant.hpp>

using namespace godot;

VARIANT_ENUM_CAST(StimulusBus::StimulusEventType);

StimulusBus *StimulusBus::_singleton = nullptr;

StimulusBus::StimulusBus() {
	_events.resize(RING_BUFFER_CAPACITY);
	_events_head = 0;
	_event_count = 0;
	// Anchor monotonic clock at construction time so timestamps are
	// small floats (seconds since bus creation) rather than absolute
	// uptime numbers that lose precision in float.
	_clock_base_seconds = (float)((double)Time::get_singleton()->get_ticks_usec() / 1.0e6);
}

StimulusBus::~StimulusBus() {
	if (_singleton == this) {
		_singleton = nullptr;
	}
}

StimulusBus *StimulusBus::get_singleton() {
	return _singleton;
}

void StimulusBus::set_singleton(StimulusBus *p_bus) {
	_singleton = p_bus;
}

void StimulusBus::install_as_singleton() {
	_singleton = this;
}

void StimulusBus::uninstall_as_singleton() {
	if (_singleton == this) {
		_singleton = nullptr;
	}
}

float StimulusBus::_now() const {
	float real = (float)((double)Time::get_singleton()->get_ticks_usec() / 1.0e6);
	return (real - _clock_base_seconds) + _clock_offset_seconds;
}

void StimulusBus::test_advance_clock(float seconds) {
	_clock_offset_seconds += seconds;
}

void StimulusBus::emit(int type, float magnitude, float raw_value,
		const Vector3 &world_position, int body_area_id,
		int source_id, int target_id, const Dictionary &extra) {
	StimulusEvent &slot = _events[_events_head];
	slot.type = type;
	slot.magnitude = magnitude;
	slot.raw_value = raw_value;
	slot.world_position = world_position;
	slot.body_area_id = body_area_id;
	slot.source_id = source_id;
	slot.target_id = target_id;
	slot.timestamp = _now();
	slot.extra = extra;

	_events_head = (_events_head + 1) % RING_BUFFER_CAPACITY;
	if (_event_count < RING_BUFFER_CAPACITY) {
		_event_count += 1;
	}
}

void StimulusBus::emit_simple(int type, const Dictionary &payload) {
	Vector3 wp;
	if (payload.has("world_position")) {
		wp = payload["world_position"];
	}
	float magnitude = payload.has("magnitude") ? (float)payload["magnitude"] : 0.0f;
	float raw_value = payload.has("raw_value") ? (float)payload["raw_value"] : 0.0f;
	int body_area_id = payload.has("body_area_id") ? (int)payload["body_area_id"] : 0;
	int source_id = payload.has("source_id") ? (int)payload["source_id"] : -1;
	int target_id = payload.has("target_id") ? (int)payload["target_id"] : -1;
	Dictionary extra;
	if (payload.has("extra")) {
		extra = payload["extra"];
	}
	emit(type, magnitude, raw_value, wp, body_area_id, source_id, target_id, extra);
}

Array StimulusBus::get_recent_events(float time_window, int type_filter) const {
	Array out;
	if (_event_count == 0) {
		return out;
	}
	float now = _now();
	float cutoff = now - time_window;
	// Walk the buffer from oldest (head - count) to newest (head - 1)
	// — chronological order, which is what subscribers usually want.
	int start = (_events_head - _event_count + RING_BUFFER_CAPACITY) % RING_BUFFER_CAPACITY;
	for (int i = 0; i < _event_count; i++) {
		int idx = (start + i) % RING_BUFFER_CAPACITY;
		const StimulusEvent &ev = _events[idx];
		if (ev.timestamp < cutoff) continue;
		if (type_filter >= 0 && ev.type != type_filter) continue;
		Dictionary d;
		d["type"] = ev.type;
		d["magnitude"] = ev.magnitude;
		d["raw_value"] = ev.raw_value;
		d["world_position"] = ev.world_position;
		d["body_area_id"] = ev.body_area_id;
		d["source_id"] = ev.source_id;
		d["target_id"] = ev.target_id;
		d["timestamp"] = ev.timestamp;
		d["extra"] = ev.extra;
		out.push_back(d);
	}
	return out;
}

int StimulusBus::get_event_count() const {
	return _event_count;
}

int StimulusBus::get_capacity() const {
	return RING_BUFFER_CAPACITY;
}

void StimulusBus::set_orifice_state_field(int64_t orifice_id, const StringName &field, float value) {
	Dictionary &state = _orifice_state[orifice_id];
	state[field] = value;
}

float StimulusBus::get_orifice_state_field(int64_t orifice_id, const StringName &field) const {
	auto it = _orifice_state.find(orifice_id);
	if (it == _orifice_state.end()) return 0.0f;
	const Dictionary &state = it->second;
	if (!state.has(field)) return 0.0f;
	return (float)state[field];
}

Dictionary StimulusBus::get_orifice_state_snapshot(int64_t orifice_id) const {
	auto it = _orifice_state.find(orifice_id);
	if (it == _orifice_state.end()) return Dictionary();
	return it->second.duplicate();
}

void StimulusBus::clear() {
	for (int i = 0; i < RING_BUFFER_CAPACITY; i++) {
		_events[i] = StimulusEvent();
	}
	_events_head = 0;
	_event_count = 0;
	_orifice_state.clear();
}

void StimulusBus::_bind_methods() {
	ClassDB::bind_method(D_METHOD("install_as_singleton"), &StimulusBus::install_as_singleton);
	ClassDB::bind_method(D_METHOD("uninstall_as_singleton"), &StimulusBus::uninstall_as_singleton);
	ClassDB::bind_method(D_METHOD("emit", "type", "magnitude", "raw_value",
									"world_position", "body_area_id", "source_id", "target_id", "extra"),
			&StimulusBus::emit);
	ClassDB::bind_method(D_METHOD("emit_simple", "type", "payload"), &StimulusBus::emit_simple);
	ClassDB::bind_method(D_METHOD("get_recent_events", "time_window", "type_filter"),
			&StimulusBus::get_recent_events, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("get_event_count"), &StimulusBus::get_event_count);
	ClassDB::bind_method(D_METHOD("get_capacity"), &StimulusBus::get_capacity);
	ClassDB::bind_method(D_METHOD("set_orifice_state_field", "orifice_id", "field", "value"),
			&StimulusBus::set_orifice_state_field);
	ClassDB::bind_method(D_METHOD("get_orifice_state_field", "orifice_id", "field"),
			&StimulusBus::get_orifice_state_field);
	ClassDB::bind_method(D_METHOD("get_orifice_state_snapshot", "orifice_id"),
			&StimulusBus::get_orifice_state_snapshot);
	ClassDB::bind_method(D_METHOD("clear"), &StimulusBus::clear);
	ClassDB::bind_method(D_METHOD("test_advance_clock", "seconds"), &StimulusBus::test_advance_clock);

	BIND_ENUM_CONSTANT(EVENT_PenetrationStart);
	BIND_ENUM_CONSTANT(EVENT_PenetrationEnd);
	BIND_ENUM_CONSTANT(EVENT_BulbPop);
	BIND_ENUM_CONSTANT(EVENT_StickSlipBreak);
	BIND_ENUM_CONSTANT(EVENT_GripEngaged);
	BIND_ENUM_CONSTANT(EVENT_GripBroke);
	BIND_ENUM_CONSTANT(EVENT_RingOverstretched);
	BIND_ENUM_CONSTANT(EVENT_HardStopBottomedOut);
	BIND_ENUM_CONSTANT(EVENT_FluidSeparation);
	BIND_ENUM_CONSTANT(EVENT_WetSeparation);
	BIND_ENUM_CONSTANT(EVENT_Impact);
	BIND_ENUM_CONSTANT(EVENT_TangentialSlap);
	BIND_ENUM_CONSTANT(EVENT_SkinPressure);
	BIND_ENUM_CONSTANT(EVENT_OrificeDamaged);
	BIND_ENUM_CONSTANT(EVENT_TentacleTangled);
	BIND_ENUM_CONSTANT(EVENT_EnvironmentalFlash);
	BIND_ENUM_CONSTANT(EVENT_LoudSound);
	BIND_ENUM_CONSTANT(EVENT_TemperatureDrop);
	BIND_ENUM_CONSTANT(EVENT_DialogueAddressed);
	BIND_ENUM_CONSTANT(EVENT_ObserverArrived);
	BIND_ENUM_CONSTANT(EVENT_RunStarted);
	BIND_ENUM_CONSTANT(EVENT_RunEnded);
	BIND_ENUM_CONSTANT(EVENT_PayloadDeposited);
	BIND_ENUM_CONSTANT(EVENT_PayloadExpelled);
	BIND_ENUM_CONSTANT(EVENT_StorageBeadMigrated);
	BIND_ENUM_CONSTANT(EVENT_RingTransitStart);
	BIND_ENUM_CONSTANT(EVENT_RingTransitEnd);
	BIND_ENUM_CONSTANT(EVENT_PhenomenonAchieved);
	BIND_ENUM_CONSTANT(EVENT_OrgasmStart);
	BIND_ENUM_CONSTANT(EVENT_OrgasmEnd);
	BIND_ENUM_CONSTANT(EVENT_GagReflexStart);
	BIND_ENUM_CONSTANT(EVENT_GagReflexEnd);
	BIND_ENUM_CONSTANT(EVENT_PainExpulsionStart);
	BIND_ENUM_CONSTANT(EVENT_PainExpulsionEnd);
	BIND_ENUM_CONSTANT(EVENT_RefusalSpasmStart);
	BIND_ENUM_CONSTANT(EVENT_RefusalSpasmEnd);
	BIND_ENUM_CONSTANT(EVENT_ContractionPulseFired);
	BIND_ENUM_CONSTANT(EVENT_KnotEngulfed);
	BIND_ENUM_CONSTANT(EVENT_EntryRejected);
}
