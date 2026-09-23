/* Capacity and encoding regressions; link the production writer to a recording DB. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "olaf_fp_db_writer.h"

static size_t emitted;
static bool deleting;
static const uint32_t identifier = 0xf1234567;

uint64_t olaf_fp_extractor_hash(struct fingerprint f){
	return (uint64_t) f.timeIndex1 + 123;
}

static void record(uint64_t *keys, uint64_t *values, size_t size, bool is_delete){
	assert(size > 0 && size <= 4096);
	assert(is_delete == deleting);
	for(size_t i = 0; i < size; i++, emitted++){
		assert(keys[i] == emitted + 123);
		assert(values[i] == ((uint64_t) emitted << 32) + identifier);
	}
}

void olaf_db_store(Olaf_DB *db, uint64_t *keys, uint64_t *values, size_t size){
	(void) db;
	record(keys, values, size, false);
}

void olaf_db_delete(Olaf_DB *db, uint64_t *keys, uint64_t *values, size_t size){
	(void) db;
	record(keys, values, size, true);
}

static void check(size_t first, size_t second, bool is_delete){
	emitted = 0;
	deleting = is_delete;
	Olaf_FP_DB_Writer *writer = olaf_fp_db_writer_new(NULL, identifier);
	size_t sizes[] = {first, second};
	size_t total = 0;
	for(size_t batch = 0; batch < 2; batch++){
		struct extracted_fingerprints f = {0};
		f.fingerprintIndex = sizes[batch];
		f.fingerprints = calloc(sizes[batch] + 1, sizeof(*f.fingerprints));
		assert(f.fingerprints);
		for(size_t i = 0; i < sizes[batch]; i++) f.fingerprints[i].timeIndex1 = (int) (total + i);
		if(is_delete) olaf_fp_db_writer_delete(writer, &f);
		else olaf_fp_db_writer_store(writer, &f);
		assert(f.fingerprintIndex == 0);
		total += sizes[batch];
		free(f.fingerprints);
	}
	olaf_fp_db_writer_destroy(writer, !is_delete);
	assert(emitted == total);
}

int main(void){
	size_t sizes[] = {0, 1, 4095, 4096, 4097, 5000, 10000};
	for(int mode = 0; mode < 2; mode++){
		for(size_t i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++) check(sizes[i], 0, mode);
		check(3000, 2000, mode);
		check(4096, 4096, mode);
	}
	puts("writer safety tests passed");
}
