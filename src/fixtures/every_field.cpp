// The same targets as every_field.c, declared through the C++ wrapper (build.hpp), which turns
// them into the C structs on its own. The test expects exactly the same description from both.
#include <weld/build.hpp>

void build(weld::Build& b) {
    b.add_executable({
        .name = "tool",
        .sources = {"tool/", "extra/tool_main.c"},
        .includes = {"tool/include/", "shared/"},
        .c_standard = weld::CStandard::c11,
        .cpp_standard = weld::CppStandard::cpp17,
    });

    b.add_library({
        .name = "shapes",
        .sources = {"lib/", "extra/circle.c", "extra/square.c"},
        .includes = {"include/", "third_party/"},
        .c_standard = weld::CStandard::gnu23,
        .cpp_standard = weld::CppStandard::cpp20,
    });
}
