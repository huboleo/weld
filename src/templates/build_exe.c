#include <weld/build.h>

void build(weld_build* b) {
    weld_executable_options options = {
        .sources = WELD_LIST("src/"),
        .c_standard = WELD_C_GNU17,
    };
    weld_add_executable(b, &options);
}
