#include <weld/build.hpp>

void build(weld::Build& b);

extern "C" void build(weld_build* raw) {
    weld::Build b(raw);
    build(b);
}
