#include <stdio.h>
#include <stdlib.h>
#include <assert.h>

#include "olaf_config.h"
#include "olaf_reader.h"
#include "olaf_db.h"

void olaf_db_mem_unpack(uint64_t packed, uint64_t * hash, uint32_t * t){
	*hash = (packed >> 16);
	*t = (uint32_t)((uint16_t) packed) ; 
}

uint64_t olaf_db_mem_pack(uint64_t hash, uint32_t t){
	uint64_t packed = 0;
	packed = (hash<<16);
	packed += t;
	return packed;
}


void olaf_reader_test(){
	const char* audio_file_name = "tests/16k_samples.raw";

	Olaf_Config *config = olaf_config_test();

	Olaf_Reader *reader = olaf_reader_new(config,audio_file_name);

	float * audio_data = (float *) malloc(config->audioBlockSize * sizeof(float));

	size_t samples_expected = config->audioStepSize;

	size_t tot_samples_read = 0;

	//read the first block
	size_t samples_read = olaf_reader_read(reader,audio_data);
	tot_samples_read += samples_read;

	while(samples_read==samples_expected){
		samples_read = olaf_reader_read(reader,audio_data);
		tot_samples_read += samples_read;
	}
	
	assert(tot_samples_read==16000);

	free(audio_data);
	olaf_reader_destroy(reader);
	olaf_config_destroy(config);
}

void olaf_db_tests(){
	Olaf_DB* db = NULL;
	printf("%s\n","Start DB tests.");
	
	Olaf_Config *config = olaf_config_test();
	db = olaf_db_new(config->dbFolder,false);

	Olaf_Resource_Meta_data d;
	d.duration = 415.153f;
	strcpy(d.path,"/home/joren/bla/t.mp3");
	d.fingerprints = 3645;

	uint32_t key = 100;

	olaf_db_store_meta_data(db,&key,&d);
	Olaf_Resource_Meta_data e;
	key = 102;
	assert(! olaf_db_has_meta_data(db,&key));
	olaf_db_find_meta_data(db,&key,&e);

	key = 100;
	assert(olaf_db_has_meta_data(db,&key));
	olaf_db_find_meta_data(db,&key,&e);

	printf("Found: '%s' %.3f %ld \n",e.path,e.duration,e.fingerprints);

	olaf_db_stats_meta_data(db,true);

	//delete
	olaf_db_delete_meta_data(db,&key);
	//Should be deleted
	assert(! olaf_db_has_meta_data(db,&key));
	olaf_db_stats_meta_data(db,true);

	uint64_t keys[] = {12l,13l,15l};
	uint64_t values[] = {112l,113l,115l};
	olaf_db_store(db,keys,values,3);

	uint64_t results[50];
	size_t number_of_results = olaf_db_find(db,11,12,results,50);;
	
	assert(number_of_results==1);
	assert(((uint32_t) results[0])==112l);

	number_of_results = olaf_db_find(db,11,13,results,50);
	assert(number_of_results==2);
	assert(((uint32_t) results[1])==113l);
	
	olaf_db_destroy(db);
	olaf_config_destroy(config);
}

void olaf_pack_test(){
	uint64_t hash = 1234567895647l;
	uint32_t t = 7895;

	uint64_t packed = olaf_db_mem_pack(hash,t);

	uint64_t unpacked_hash = 0;
	uint32_t unpacked_t = 0;
	olaf_db_mem_unpack(packed,&unpacked_hash,&unpacked_t);

	assert(unpacked_hash == hash);
	assert(unpacked_t == t);

	fprintf(stdout,"Passed pack test, %d %lld \n",unpacked_t , unpacked_hash);
}

int main(int argc, const char* argv[]){
	(void)(argc);
	(void)(argv);
	olaf_db_tests();
	olaf_reader_test();
	olaf_pack_test();
}
