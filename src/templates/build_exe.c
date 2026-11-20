#include <weld/build.h>

void build(weld_build* b) {
    weld_executable_options options = {
        .sources = WELD_LIST("src/"),
    };
    weld_add_executable(b, &options);
}
