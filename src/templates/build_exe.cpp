#include <weld/build.hpp>

void build(weld::Build& b) {
    b.add_executable({
        .sources = {"src/"},
    });
}
