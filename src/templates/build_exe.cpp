#include <weld/build.hpp>

void build(weld::Build& b) {
    b.add_executable({
        .sources = {"src/"},
        .cpp_standard = weld::CppStandard::cpp23,
    });
}
