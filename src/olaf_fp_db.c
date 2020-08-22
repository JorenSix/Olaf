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

#include "lmdb.h"
#include "olaf_fp_db.h"


struct Olaf_FP_DB{
	//the file name to serialize and deserialize the data
	MDB_env *env;
	MDB_txn *txn;
	MDB_dbi dbi;

};

void e(int status_code){
	if (status_code != MDB_SUCCESS) {
		fprintf(stderr, "Database Error: %s\n", mdb_strerror(status_code));
		exit(-42);
	}
}

Olaf_FP_DB * olaf_fp_db_new(const char * mdb_folder,bool readonly){

	Olaf_FP_DB *olaf_fp_db = (Olaf_FP_DB*) malloc(sizeof(Olaf_FP_DB));

	e(mdb_env_create(&olaf_fp_db->env));
	e(mdb_env_set_maxreaders(olaf_fp_db->env, 5));
	e(mdb_env_set_mapsize(olaf_fp_db->env,  100 * 10485760));
	e(mdb_env_open(olaf_fp_db->env, mdb_folder, readonly ? (MDB_RDONLY | MDB_NOLOCK) : 0, 0664));
	e(mdb_txn_begin(olaf_fp_db->env, NULL, readonly ? MDB_RDONLY : 0 , &olaf_fp_db->txn));

	unsigned int flags = MDB_INTEGERKEY | MDB_DUPSORT | MDB_DUPFIXED | MDB_INTEGERDUP;

	//set as create if not readonly
	if(! readonly){
		flags = flags | MDB_CREATE;
	}

	//open the database with flags sets
	e(mdb_dbi_open(olaf_fp_db->txn, NULL,flags , &olaf_fp_db->dbi));

	return olaf_fp_db;
}

//string to unsigned 32 bit hash
uint32_t olaf_fp_db_string_hash(const char *key, size_t len){

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

void olaf_fp_db_store(Olaf_FP_DB * olaf_fp_db,uint32_t * keys,uint64_t * values, size_t size){
	MDB_val mdb_key, mdb_value;

	//store
	for(size_t i = 0 ; i < size ; i++){
		uint32_t key =  keys[i];
		uint64_t value = values[i];

		mdb_key.mv_size = sizeof(uint32_t);
		mdb_key.mv_data = &key;

		mdb_value.mv_size = sizeof(uint64_t);
		mdb_value.mv_data = &value;

		//printf("store: %u %u \n",key,value);

		mdb_put(olaf_fp_db->txn, olaf_fp_db->dbi, &mdb_key, &mdb_value, 0);
	}
}

void olaf_fp_db_find(Olaf_FP_DB * olaf_fp_db,uint32_t key,int bits_to_ignore, uint64_t * results, size_t results_size, size_t * number_of_results){
	//ignore the x first bits
	

	//int v = 0b10001;
	//int start_v = (v>>3)<<3;
	//int stop_v = start_v | ((1<<3) - 1);
	//printf("%d %d %d\n",v,start_v,stop_v);

	uint32_t start_key = (key>>bits_to_ignore)<<bits_to_ignore;

	//to prevent overflow use a 64 bit value
	uint32_t v = 1;

	uint32_t stop_key = start_key | ((v<<bits_to_ignore)-1);

	//printf("%u %u \n",start_key,stop_key);

	int rc;
	MDB_cursor *cursor;
	MDB_val mdb_key, mdb_value;

	e(mdb_cursor_open(olaf_fp_db->txn, olaf_fp_db->dbi, &cursor));

	mdb_key.mv_size = sizeof(uint32_t);
	mdb_key.mv_data = &start_key;

	uint64_t s = 0;
	mdb_value.mv_size = sizeof(uint64_t);
	mdb_value.mv_data = &s;

	size_t result_index = 0;


	//Position at first key greater than or equal to specified key.
	rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_SET_RANGE );

	//query
	do {
		uint32_t keyInt = *((uint32_t *) (mdb_key.mv_data));
		uint64_t valueInt = *((uint64_t *) (mdb_value.mv_data));

		if( keyInt > stop_key) break;

		//printf("key:  %p %u, value: %p  %u \n",mdb_key.mv_data,keyInt,mdb_value.mv_data,valueInt);

		if(result_index >= results_size){
			printf("Results full\n");
			break;
		} 

		results[result_index] = valueInt;
		result_index++;
		*number_of_results = result_index; 

		rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT_DUP );

		if(rc == MDB_NOTFOUND ){
			//printf("No Next Dup for key:  %p %u \n",mdb_key.mv_data,keyInt);

			rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT);
		}
		//if(keyInt!=100) break;
	} while (rc == 0);

	mdb_cursor_close(cursor);
}

void olaf_fp_db_stats(Olaf_FP_DB * olaf_fp_db){
	/* Get a database statistics */
	MDB_stat stats;
	int err = mdb_stat(olaf_fp_db->txn, olaf_fp_db->dbi, &stats);
	if (err == MDB_SUCCESS) {
		printf("[MDB database statistics]\n");
		printf("=========================\n");
		printf("> Size of database page:        %u\n", stats.ms_psize);
		printf("> Depth of the B-tree:          %u\n", stats.ms_depth);
		printf("> Number of items in databases: %d\n", (int)stats.ms_entries);
		printf("=========================\n\n");
	} else {
		fprintf(stderr, "Can't retrieve the database statistics: %s\n", mdb_strerror(err));
	}
}


//free memory resources
void olaf_fp_db_destroy(Olaf_FP_DB * olaf_fp_db){
	mdb_dbi_close(olaf_fp_db->env, olaf_fp_db->dbi);
	mdb_txn_commit(olaf_fp_db->txn);
	mdb_env_close(olaf_fp_db->env);
	free(olaf_fp_db);
}
