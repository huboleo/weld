#include <weld/build.h>

void build(weld_build* b) {
    weld_library_options options = {
        .name = "WELD_NAME",
        .sources = WELD_LIST("src/"),
        .includes = WELD_LIST("include/"),
        .c_standard = WELD_C_GNU17,
    };
    weld_add_library(b, &options);
}
