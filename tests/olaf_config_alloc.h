#ifndef OLAF_CONFIG_ALLOC_H
#define OLAF_CONFIG_ALLOC_H
#include <stdlib.h>
#include <string.h>
void * olaf_test_malloc(size_t size);
void * olaf_test_calloc(size_t count, size_t size);
char * olaf_test_strdup(const char * text);
void olaf_test_free(void * pointer);
#define malloc olaf_test_malloc
#define calloc olaf_test_calloc
#define strdup olaf_test_strdup
#define free olaf_test_free
#endif
