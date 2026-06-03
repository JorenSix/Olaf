#include <check.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/wait.h>

START_TEST(test_buffer_read_bounds_strcpy_overflow)
{
    // Invariant: Buffer reads never exceed declared length; oversized paths must not cause out-of-bounds access
    const char *payloads[] = {
        "valid/short/path.wav",