#include <weld/build.hpp>

void build(weld::Build& b) {
    b.add_library({
        .name = "WELD_NAME",
        .sources = {"src/"},
        .includes = {"include/"},
        .cpp_standard = weld::CppStandard::cpp23,
    });
}
