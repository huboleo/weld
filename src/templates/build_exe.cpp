#include <weld/build.hpp>

void build(weld::Build& b) {
    b.add_executable({
        .name = "WELD_NAME",
        .sources = {"src/"},
        .cpp_standard = weld::CppStandard::cpp23,
    });
}
