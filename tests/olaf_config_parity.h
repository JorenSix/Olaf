#ifndef OLAF_CONFIG_PARITY_H
#define OLAF_CONFIG_PARITY_H
#include "olaf_fp_extractor.h"
/* Test-only entry point: exercise compiled C rather than Zig's translation
 * of platform-specific math macros in the private inline validators. */
const char * olaf_test_config_error(const Olaf_Config * config);
#endif
