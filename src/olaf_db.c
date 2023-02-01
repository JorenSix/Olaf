// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2020  Joren Six

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <assert.h>
#include <stdbool.h>
#include <string.h>

#include "lmdb.h"
#include "olaf_db.h"

struct Olaf_DB{
	//the file name to serialize and deserialize the data
	MDB_env *env;
	MDB_txn *txn;

	MDB_dbi dbi_fps;
	MDB_dbi dbi_resource_map;

	bool warning_given;

	const char * mdb_folder;
};

void e(int status_code){
	if (status_code != MDB_SUCCESS) {
		fprintf(stderr, "Database Error: %s\n", mdb_strerror(status_code));
		exit(-42);
	}
}

Olaf_DB * olaf_db_new(const char * mdb_folder,bool readonly){

	Olaf_DB *olaf_db = (Olaf_DB *) malloc(sizeof(Olaf_DB));

	olaf_db->warning_given = false;

	//configure the max db size in bytes to be 1TB
	//Fails silently when 1TB is reached
	//see here:
	//mdb_env_set_mapsize function in http://www.lmdb.tech/doc/group__mdb.html
	//
	size_t max_db_size_in_bytes = (size_t)(1024*1024) * (size_t)(1024*1024);

	e(mdb_env_create(&olaf_db->env));
	e(mdb_env_set_maxreaders(olaf_db->env, 10));
	e(mdb_env_set_mapsize(olaf_db->env,max_db_size_in_bytes));
	e(mdb_env_set_maxdbs(olaf_db->env,2));
	e(mdb_env_open(olaf_db->env, mdb_folder, readonly ? (MDB_RDONLY | MDB_NOLOCK) : 0, 0664));
	e(mdb_txn_begin(olaf_db->env, NULL, readonly ? MDB_RDONLY : 0 , &olaf_db->txn));

	unsigned int fingerprint_flags = MDB_INTEGERKEY | MDB_DUPSORT | MDB_DUPFIXED | MDB_INTEGERDUP;
	unsigned int resource_flags = MDB_INTEGERKEY;

	//set as create if not readonly
	if(!readonly){
		fingerprint_flags |= MDB_CREATE;
		resource_flags |= MDB_CREATE;
	}

	//open the database with flags sets
	e(mdb_dbi_open(olaf_db->txn, "olaf_fingerprints",fingerprint_flags , &olaf_db->dbi_fps));
	e(mdb_dbi_open(olaf_db->txn, "olaf_resource_map",resource_flags , &olaf_db->dbi_resource_map));

	olaf_db->mdb_folder = mdb_folder;

	return olaf_db;
}

//string to unsigned 32 bit hash
uint32_t olaf_db_string_hash(const char *key, size_t len){

	//from wikipedia: jenkins_one_at_a_time_hash
	//https://en.wikipedia.org/wiki/Jenkins_hash_function
	uint32_t hash, i;

	for(hash = i = 0; i < len; ++i){
		hash += key[i];
		hash += (hash << 10);
		hash ^= (hash >> 6);
	}

	hash += (hash << 3);
	hash ^= (hash >> 11);
	hash += (hash << 15);

	return hash;
}

void olaf_db_store_internal(Olaf_DB * olaf_db,uint64_t * keys,uint64_t * values, size_t size,unsigned int flags){
	MDB_val mdb_key, mdb_value;

	//store
	for(size_t i = 0 ; i < size ; i++){
		uint64_t key =  keys[i];
		uint64_t value = values[i];

		mdb_key.mv_size = sizeof(uint64_t);
		mdb_key.mv_data = &key;

		mdb_value.mv_size = sizeof(uint64_t);
		mdb_value.mv_data = &value;

		mdb_put(olaf_db->txn, olaf_db->dbi_fps, &mdb_key, &mdb_value, flags);
	}
}

//store the meta data 
void olaf_db_store_meta_data(Olaf_DB * olaf_db, uint32_t * key, Olaf_Resource_Meta_data * value){
	MDB_val mdb_key, mdb_value;

	mdb_key.mv_size = sizeof(uint32_t);
	mdb_key.mv_data = key;

	Olaf_Resource_Meta_data r;
	strcpy(r.path,value->path);
	r.duration = value->duration;
	r.fingerprints = value->fingerprints;

	mdb_value.mv_size = sizeof(Olaf_Resource_Meta_data);
	mdb_value.mv_data = &r;

	//printf("Storing: %s %f %ld \n" ,value->path, value->duration, value->fingerprints);

	e(mdb_put(olaf_db->txn, olaf_db->dbi_resource_map, &mdb_key, &mdb_value,0));
}

void olaf_db_delete_meta_data(Olaf_DB * olaf_db, uint32_t * key){
	MDB_val mdb_key, mdb_value;

	mdb_key.mv_size = sizeof(uint32_t);
	mdb_key.mv_data = key;

	Olaf_Resource_Meta_data r;
	
	mdb_value.mv_size = sizeof(Olaf_Resource_Meta_data);
	mdb_value.mv_data = &r;

	e(mdb_del(olaf_db->txn, olaf_db->dbi_resource_map, &mdb_key, &mdb_value));
}

//return meta data
void olaf_db_find_meta_data(Olaf_DB * olaf_db, uint32_t * key, Olaf_Resource_Meta_data * value){
	MDB_val mdb_key, mdb_value;

	mdb_key.mv_size = sizeof(uint32_t);
	mdb_key.mv_data = key;

	Olaf_Resource_Meta_data r;

	mdb_value.mv_size = sizeof(Olaf_Resource_Meta_data);
	mdb_value.mv_data = &r;

	int result = mdb_get(olaf_db->txn, olaf_db->dbi_resource_map, &mdb_key, &mdb_value);

	if(result == 0){
		r = *((Olaf_Resource_Meta_data *) (mdb_value.mv_data));

		strcpy(value->path,r.path);
		value->duration=r.duration;
		value->fingerprints = r.fingerprints;
		//printf("For key %u, meta data: '%s'  %ld %f \n",*key ,r.path,r.fingerprints,r.duration);
	}else if (result == MDB_NOTFOUND){
		printf("No meta data with key %u \n", *key);
	}
}

void olaf_db_stats_meta_data(Olaf_DB * olaf_db,bool verbose){
	int rc;
	MDB_cursor *cursor;
	MDB_val mdb_key, mdb_value;

	e(mdb_cursor_open(olaf_db->txn, olaf_db->dbi_resource_map, &cursor));

	uint32_t key = 0;
	mdb_key.mv_size = sizeof(uint32_t);
	mdb_key.mv_data = &key;

	Olaf_Resource_Meta_data r;

	mdb_value.mv_size = sizeof(Olaf_Resource_Meta_data);
	mdb_value.mv_data = &r;

	//Position at first key greater than or equal to specified key.
	rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_SET_RANGE);

	if(rc != 0){
		printf("Number of songs (#):\t%u\n",0);
		printf("Total duration (s):\t%.3f\n",0.0f);
		printf("Avg prints/s (fp/s):\t%.3f\n",0.0f);
		return;
	}

	float total_seconds = 0;
	long total_prints = 0;
	uint32_t number_of_items = 0;

	printf("  key  \tduration(s)\tPrints(#)\tPrints(#/s)\tpath\n");
	//query
	do {
		uint32_t keyInt = *((uint32_t *) (mdb_key.mv_data));
		Olaf_Resource_Meta_data val = *((Olaf_Resource_Meta_data *) (mdb_value.mv_data));

		float fps_per_second =  (float) val.fingerprints / val.duration;

		total_seconds+= val.duration;
		total_prints+= val.fingerprints;
		number_of_items += 1;

		if(verbose){
			printf("%12u\t%.3fs\t%6ldfps\t%.3ffps/s\t'%s'\n",keyInt,val.duration,val.fingerprints,fps_per_second,val.path);
		}
		
		rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT);

	} while (rc == 0);

	float fps_per_second =  (float) total_prints / total_seconds;

	printf("Number of songs (#):\t%u\n",number_of_items);
	printf("Total duration (s):\t%.3f\n",total_seconds);
	printf("Avg prints/s (fp/s):\t%.3f\n",fps_per_second);
	printf("\n");
}

bool olaf_db_has_meta_data(Olaf_DB * olaf_db, uint32_t * key){
	MDB_val mdb_key, mdb_value;

	mdb_key.mv_size = sizeof(uint32_t);
	mdb_key.mv_data = key;

	mdb_value.mv_size = sizeof(Olaf_Resource_Meta_data);
	mdb_value.mv_data = NULL;

	int result = mdb_get(olaf_db->txn, olaf_db->dbi_resource_map, &mdb_key, &mdb_value);

	return result == 0;
}

void olaf_db_store(Olaf_DB * olaf_db,uint64_t * keys,uint64_t * values, size_t size){
	olaf_db_store_internal(olaf_db,keys,values,size,0);
}

void olaf_db_delete(Olaf_DB * olaf_db,uint64_t * keys,uint64_t * values, size_t size){
	MDB_val mdb_key, mdb_value;

	//store
	for(size_t i = 0 ; i < size ; i++){
		uint64_t key =  keys[i];
		uint64_t value = values[i];

		mdb_key.mv_size = sizeof(uint64_t);
		mdb_key.mv_data = &key;

		mdb_value.mv_size = sizeof(uint64_t);
		mdb_value.mv_data = &value;

		//printf("store: %u %u \n",key,value);

		mdb_del(olaf_db->txn, olaf_db->dbi_fps, &mdb_key, &mdb_value);
	}
}
bool olaf_db_find_single(Olaf_DB * olaf_db,uint64_t start_key,uint64_t stop_key){
	uint64_t results[1];
	return 0 != olaf_db_find(olaf_db,start_key,stop_key,results,1);
}

size_t olaf_db_find(Olaf_DB * olaf_db,uint64_t start_key,uint64_t stop_key, uint64_t * results, size_t results_size){
	//fprintf(stderr,"start key: %u stop key: %u \n",start_key,stop_key);
	int rc;
	size_t number_of_results = 0;
	MDB_cursor *cursor;
	MDB_val mdb_key, mdb_value;

	e(mdb_cursor_open(olaf_db->txn, olaf_db->dbi_fps, &cursor));

	mdb_key.mv_size = sizeof(uint64_t);
	mdb_key.mv_data = &start_key;

	uint64_t s = 0;
	mdb_value.mv_size = sizeof(uint64_t);
	mdb_value.mv_data = &s;

	size_t result_index = 0;

	//Position at first key greater than or equal to specified key.
	rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_SET_RANGE );

	//query
	do {

		uint64_t keyInt = *((uint64_t *) (mdb_key.mv_data));
		uint64_t valueInt = *((uint64_t *) (mdb_value.mv_data));

		if( keyInt > stop_key) break;

		//fprintf(stderr,"Found key:  %p %llu, value: %p  %llu \n",mdb_key.mv_data,keyInt,mdb_value.mv_data,valueInt);

		if(result_index >= results_size){
			//warn only once!
			if(!olaf_db->warning_given){
				olaf_db->warning_given = true;
				fprintf(stderr,"Warning: Results full, expected less than %zu hash collisions, configure config->maxDBCollisions to a higher number for larger indexex \n",results_size);
			}
			break;
		}

		//ignore empty results, currently unsure why these
		//are present: check DB API call order to verify 
		if(valueInt != 0){
			results[result_index] = valueInt;
			result_index++;
			number_of_results = result_index; 
		}

		rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT_DUP );
		if(rc == MDB_NOTFOUND ){
			//printf("No Next Dup for key:  %p %llu \n",mdb_key.mv_data,keyInt);
			rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT);
		}

	} while (rc == 0);

	mdb_cursor_close(cursor);

	//fprintf(stderr,"start key: %llu stop key: %llu  results %zu \n",start_key,stop_key,number_of_results);

	return number_of_results;
}

size_t olaf_db_size(Olaf_DB * olaf_db){
	//This assumes the default filename for MDB
	const char* mdb_filename = "data.mdb";

	//This limits the full path to a rather random
	//700 characters
	char mdb_full_path_name[700];

	strcpy(mdb_full_path_name, olaf_db->mdb_folder);
	strcat(mdb_full_path_name,mdb_filename);

	FILE * db_file = fopen(mdb_full_path_name,"rb");
	fseek (db_file , 0 , SEEK_END);
	size_t fp_db_size_in_bytes = ftell(db_file);
	fclose(db_file);
	
	return fp_db_size_in_bytes;
}

void olaf_db_stats_verbose(Olaf_DB * olaf_db){
	int rc;
	MDB_cursor *cursor;
	MDB_val mdb_key, mdb_value;

	e(mdb_cursor_open(olaf_db->txn, olaf_db->dbi_fps, &cursor));

	uint64_t key = 0;
	mdb_key.mv_size = sizeof(uint64_t);
	mdb_key.mv_data = &key;

	uint64_t value;
	mdb_value.mv_size = sizeof(uint64_t);
	mdb_value.mv_data = &value;

	//Position at first key greater than or equal to specified key.
	rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_SET_RANGE);

	if(rc != 0){
		printf("Total fingerprints:\t%u\n",0);
		return;
	}

	uint64_t number_of_fps = 0;

	printf("  key  \tduration(s)\tPrints(#)\tPrints(#/s)\tpath\n");
	//query
	do {
		uint64_t hash = *((uint64_t *) (mdb_key.mv_data));
		uint64_t val = *((uint64_t *) (mdb_value.mv_data));

		uint32_t ref_t1 = (uint32_t) (val >> 32);
		uint32_t ref_id = (uint32_t) val;

		number_of_fps++;
		printf("%12llu\t%12llu: [%8d,%8d]\n",number_of_fps,hash,ref_id,ref_t1);
		
		rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT_DUP );
		if(rc == MDB_NOTFOUND ){
			rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT);
		}
	} while (rc == 0);
	printf("Total fingerprints:\t%llu\n",number_of_fps);
}

void olaf_db_stats(Olaf_DB * olaf_db,bool verbose){
	if(verbose){
		olaf_db_stats_verbose(olaf_db);
	}

	/* Get a database statistics */
	MDB_stat stats;
	int err = mdb_stat(olaf_db->txn, olaf_db->dbi_fps, &stats);
	if (err == MDB_SUCCESS) {
		printf("[MDB database statistics]\n");
		printf("=========================\n");
		printf("> Size of database page:        %u\n", stats.ms_psize);
		printf("> Depth of the B-tree:          %u\n", stats.ms_depth);
		printf("> Number of items in databases: %d\n", (int)stats.ms_entries);
		printf("> File size of the databases:   %luMB\n", olaf_db_size(olaf_db) / (1024 * 1024));
		printf("=========================\n\n");

		olaf_db_stats_meta_data(olaf_db,true);
	} else {
		fprintf(stderr, "Can't retrieve the database statistics: %s\n", mdb_strerror(err));
	}
}

//free memory resources
void olaf_db_destroy(Olaf_DB * olaf_db){

	//mdb_dbi_close(olaf_db->env, olaf_db->dbi_fps);
	//mdb_dbi_close(olaf_db->env, olaf_db->dbi_resource_map);

	mdb_txn_commit(olaf_db->txn);
	mdb_env_close(olaf_db->env);

	free(olaf_db);
}
