#include <weld/build.hpp>

void build(weld::Build& b) {
    b.add_library({
        .sources = {"src/"},
        .includes = {"include/"},
    });
}
