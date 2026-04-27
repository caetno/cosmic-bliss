#pragma once

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace udon::log {

inline void info(const godot::String &p_msg) {
    godot::UtilityFunctions::print(godot::String("[tenticles] ") + p_msg);
}

inline void warn(const godot::String &p_msg) {
    godot::UtilityFunctions::push_warning(godot::String("[tenticles] ") + p_msg);
}

inline void error(const godot::String &p_msg) {
    godot::UtilityFunctions::push_error(godot::String("[tenticles] ") + p_msg);
}

} // namespace udon::log
