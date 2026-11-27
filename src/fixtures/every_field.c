// Calls every weld_* function with every field filled, for the end-to-end test of the C boundary
// in script.zig. Every value is different and none is a default, so a field that is dropped or
// swapped on its way to the description makes the test fail. every_field.cpp declares the same
// targets through the C++ wrapper.
#include <weld/build.h>

void build(weld_build* b) {
    weld_executable_options tool = {
        .name = "tool",
        .sources = WELD_LIST("tool/", "extra/tool_main.c"),
        .includes = WELD_LIST("tool/include/", "shared/"),
        .c_standard = WELD_C_11,
        .cpp_standard = WELD_CPP_17,
    };
    weld_add_executable(b, &tool);

    weld_library_options shapes = {
        .name = "shapes",
        .sources = WELD_LIST("lib/", "extra/circle.c", "extra/square.c"),
        .includes = WELD_LIST("include/", "third_party/"),
        .c_standard = WELD_C_GNU23,
        .cpp_standard = WELD_CPP_20,
    };
    weld_add_library(b, &shapes);
}
