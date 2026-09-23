// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2025  Joren Six

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
#include <inttypes.h>
#include <pthread.h>

#include "lmdb.h"
#include "olaf_db.h"

//The registry owns one environment per directory identity. Handles retain an
//entry before waiting for initialization or a transaction, so neither can race
//the last close. The registry lock is never held while beginning a transaction.
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif
#include <errno.h>

struct Olaf_DB_Identity{
#ifdef _WIN32
	DWORD volume;
	DWORD index_high;
	DWORD index_low;
#else
	dev_t device;
	ino_t inode;
#endif
};

struct Olaf_DB_Environment{
	struct Olaf_DB_Identity identity;
	char *path;
	MDB_env *env;
	MDB_dbi dbi_fps;
	MDB_dbi dbi_resource_map;
	size_t references;
	pthread_mutex_t initialized;
	pthread_mutex_t writer; /**< Serializes this environment's write handle lifetime */
	pthread_mutex_t snapshots; /**< Coordinates snapshot registration with writer operations */
	int status;
	struct Olaf_DB_Environment *next;
};

static pthread_mutex_t olaf_db_registry_lock = PTHREAD_MUTEX_INITIALIZER;
//LMDB requires transactions opening DBIs to finish before another such
//transaction starts. This mutex is not used by ordinary reader/writer handles.
static pthread_mutex_t olaf_db_dbi_lock = PTHREAD_MUTEX_INITIALIZER;
static struct Olaf_DB_Environment *olaf_db_environments = NULL;

struct Olaf_DB{
	struct Olaf_DB_Environment *shared; /**< Retained environment */
	MDB_txn *txn; /**< Owned transaction, used serially by this handle */
	MDB_dbi dbi_fps; /**< Borrowed from shared */
	MDB_dbi dbi_resource_map; /**< Borrowed from shared */
	bool readonly;
	bool warning_given;
	const char *mdb_folder; /**< Borrowed from shared, never from the caller */
};

void e_ctx(int status_code, const char *operation, const char *db_folder) {
	if (status_code != MDB_SUCCESS) {
		fprintf(stderr, "Database Error in '%s': %s\n", operation, mdb_strerror(status_code));
		if (db_folder) {
			fprintf(stderr, "  Database folder: '%s'\n", db_folder);
			fprintf(stderr, "  Hint: Ensure the folder exists and is writable (mkdir -p %s)\n", db_folder);
		}
		exit(-42);
	}
}

void e(int status_code){
	e_ctx(status_code,"database operation",NULL);
}

static bool olaf_db_same_identity(struct Olaf_DB_Identity a,struct Olaf_DB_Identity b){
#ifdef _WIN32
	return a.volume == b.volume && a.index_high == b.index_high && a.index_low == b.index_low;
#else
	return a.device == b.device && a.inode == b.inode;
#endif
}

//Inspect the directory, not data.mdb: closing an extra descriptor for an LMDB
//file can release process-associated locks. Own the absolute path as well.
static int olaf_db_directory(const char *folder,struct Olaf_DB_Identity *identity,char **path){
#ifdef _WIN32
	HANDLE dir = CreateFileA(folder,0,FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
		NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
	if(dir == INVALID_HANDLE_VALUE) return (int) GetLastError();
	BY_HANDLE_FILE_INFORMATION info;
	int status = 0;
	if(!GetFileInformationByHandle(dir,&info)) status = (int) GetLastError();
	if(!status && !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) status = ERROR_DIRECTORY;
	DWORD length = 0;
	if(!status){
		length = GetFinalPathNameByHandleA(dir,NULL,0,FILE_NAME_NORMALIZED);
		if(!length) status = (int) GetLastError();
	}
	if(!status){
		*path = malloc((size_t) length + 1);
		if(!*path) status = ENOMEM;
		else {
			DWORD actual = GetFinalPathNameByHandleA(dir,*path,length + 1,FILE_NAME_NORMALIZED);
			if(!actual || actual > length){
				status = actual ? ERROR_INSUFFICIENT_BUFFER : (int) GetLastError();
				free(*path);
				*path = NULL;
			}
		}
	}
	CloseHandle(dir);
	if(!status){
		identity->volume = info.dwVolumeSerialNumber;
		identity->index_high = info.nFileIndexHigh;
		identity->index_low = info.nFileIndexLow;
	}
	return status;
#else
	*path = realpath(folder,NULL);
	if(!*path) return errno;
	struct stat info;
	int status = 0;
	if(stat(*path,&info) != 0) status = errno;
	else if(!S_ISDIR(info.st_mode)) status = ENOTDIR;
	if(status){
		free(*path);
		*path = NULL;
		return status;
	}
	identity->device = info.st_dev;
	identity->inode = info.st_ino;
	return 0;
#endif
}

static int olaf_db_environment_init(struct Olaf_DB_Environment *shared,bool readonly){
	//A readonly request must not create a missing database. The shared env is
	//write-capable, but each reader uses a strictly readonly transaction. The
	//bundled LMDB already needs write access to data.mdb even with MDB_RDONLY.
	if(readonly){
		size_t size = strlen(shared->path) + sizeof("/data.mdb");
		char *file = malloc(size);
		if(!file) return ENOMEM;
		#ifdef _WIN32
		snprintf(file,size,"%s\\data.mdb",shared->path);
		DWORD attributes = GetFileAttributesA(file);
		int status = attributes == INVALID_FILE_ATTRIBUTES ? (int) GetLastError() : 0;
#else
		snprintf(file,size,"%s/data.mdb",shared->path);
		struct stat info;
		int status = stat(file,&info) == 0 ? 0 : errno;
#endif
		free(file);
		if(status) return status;
	}

	int status = mdb_env_create(&shared->env);
	if(status) return status;
	if((status = mdb_env_set_maxreaders(shared->env,1024))) return status;
	size_t mapsize = (size_t)(1024*1024) * (size_t)(1024*1024);
	if((status = mdb_env_set_mapsize(shared->env,mapsize))) return status;
	if((status = mdb_env_set_maxdbs(shared->env,2))) return status;
	if((status = mdb_env_open(shared->env,shared->path,MDB_NOTLS,0664))) return status;

	pthread_mutex_lock(&olaf_db_dbi_lock);
	MDB_txn *txn = NULL;
	status = mdb_txn_begin(shared->env,NULL,readonly ? MDB_RDONLY : 0,&txn);
	unsigned int create = readonly ? 0 : MDB_CREATE;
	if(!status) status = mdb_dbi_open(txn,"olaf_fingerprints",
		MDB_INTEGERKEY | MDB_DUPSORT | MDB_DUPFIXED | MDB_INTEGERDUP | create,&shared->dbi_fps);
	if(!status) status = mdb_dbi_open(txn,"olaf_resource_map",MDB_INTEGERKEY | create,&shared->dbi_resource_map);
	//Commit even the initial read transaction: this publishes DBI handles.
	if(!status) status = mdb_txn_commit(txn);
	else if(txn) mdb_txn_abort(txn);
	pthread_mutex_unlock(&olaf_db_dbi_lock);
	return status;
}

static void olaf_db_environment_release(struct Olaf_DB_Environment *shared){
	pthread_mutex_lock(&olaf_db_registry_lock);
	if(--shared->references == 0){
		struct Olaf_DB_Environment **entry = &olaf_db_environments;
		while(*entry != shared) entry = &(*entry)->next;
		*entry = shared->next;
		//Keep acquisition excluded until the old mapping and descriptors close.
		if(shared->env) mdb_env_close(shared->env);
		pthread_mutex_destroy(&shared->snapshots);
		pthread_mutex_destroy(&shared->writer);
		pthread_mutex_destroy(&shared->initialized);
		free(shared->path);
		free(shared);
	}
	pthread_mutex_unlock(&olaf_db_registry_lock);
}

Olaf_DB * olaf_db_new(const char *mdb_folder,bool readonly){
	struct Olaf_DB_Identity identity;
	char *path = NULL;
	e_ctx(olaf_db_directory(mdb_folder,&identity,&path),"database directory",mdb_folder);
	Olaf_DB *db = calloc(1,sizeof(Olaf_DB));
	if(!db){
		free(path);
		e_ctx(ENOMEM,"database handle",mdb_folder);
		return NULL;
	}

	pthread_mutex_lock(&olaf_db_registry_lock);
	struct Olaf_DB_Environment *shared = olaf_db_environments;
	while(shared && !olaf_db_same_identity(shared->identity,identity)) shared = shared->next;
	bool initialize = shared == NULL;
	if(initialize){
		shared = calloc(1,sizeof(*shared));
		int status = shared ? pthread_mutex_init(&shared->initialized,NULL) : ENOMEM;
		if(!status){
			status = pthread_mutex_init(&shared->writer,NULL);
			if(status) pthread_mutex_destroy(&shared->initialized);
			else {
				status = pthread_mutex_init(&shared->snapshots,NULL);
				if(status){
					pthread_mutex_destroy(&shared->writer);
					pthread_mutex_destroy(&shared->initialized);
				}
			}
		}
		if(status){
			free(shared);
			pthread_mutex_unlock(&olaf_db_registry_lock);
			free(path);
			free(db);
			e_ctx(status,"environment allocation",mdb_folder);
			return NULL;
		}
		shared->identity = identity;
		shared->path = path;
		path = NULL;
		pthread_mutex_lock(&shared->initialized);
		shared->next = olaf_db_environments;
		olaf_db_environments = shared;
	}
	shared->references++;
	pthread_mutex_unlock(&olaf_db_registry_lock);
	free(path);

	if(initialize){
		shared->status = olaf_db_environment_init(shared,readonly);
		pthread_mutex_unlock(&shared->initialized);
	}else{
		pthread_mutex_lock(&shared->initialized);
		pthread_mutex_unlock(&shared->initialized);
	}
	int status = shared->status;
	if(!status){
		//This LMDB version reads its reusable writer's flags before acquiring
		//its writer lock. Serialize local writers before entering mdb_txn_begin.
		//LMDB scans reader slots without locking during writes. Coordinate
		//snapshot begin/end with writer operations, never reader lifetimes.
		//Do not hold the snapshot lock while waiting for an external writer.
		pthread_mutex_t *lock = readonly ? &shared->snapshots : &shared->writer;
		pthread_mutex_lock(lock);
		status = mdb_txn_begin(shared->env,NULL,readonly ? MDB_RDONLY : 0,&db->txn);
		if(readonly || status) pthread_mutex_unlock(lock);
	}
	if(status){
		olaf_db_environment_release(shared);
		free(db);
		e_ctx(status,"environment/transaction open",mdb_folder);
		return NULL;
	}
	db->shared = shared;
	db->readonly = readonly;
	db->mdb_folder = shared->path;
	db->dbi_fps = shared->dbi_fps;
	db->dbi_resource_map = shared->dbi_resource_map;
	return db;
}

#ifdef OLAF_DB_TESTING
//Test-build-only inspection; deliberately absent from the public header.
const void *olaf_db_test_environment(Olaf_DB *db){
	return db->shared->env;
}

size_t olaf_db_test_environment_count(void){
	size_t count = 0;
	pthread_mutex_lock(&olaf_db_registry_lock);
	for(struct Olaf_DB_Environment *s = olaf_db_environments; s; s = s->next) count++;
	pthread_mutex_unlock(&olaf_db_registry_lock);
	return count;
}
#endif

//olaf_db_string_hash and olaf_db_identifier_id are implemented in
//olaf_db_id.c, shared with the other database implementations

void olaf_db_store_internal(Olaf_DB * olaf_db,uint64_t * keys,uint64_t * values, size_t size,unsigned int flags){
	pthread_mutex_lock(&olaf_db->shared->snapshots);
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
	pthread_mutex_unlock(&olaf_db->shared->snapshots);
}

//store the meta data 
void olaf_db_store_meta_data(Olaf_DB * olaf_db, uint32_t * key, Olaf_Resource_Meta_data * value){
	MDB_val mdb_key, mdb_value;

	mdb_key.mv_size = sizeof(uint32_t);
	mdb_key.mv_data = key;

	Olaf_Resource_Meta_data r;
	snprintf(r.path,sizeof(r.path),"%s",value->path);
	r.duration = value->duration;
	r.fingerprints = value->fingerprints;

	mdb_value.mv_size = sizeof(Olaf_Resource_Meta_data);
	mdb_value.mv_data = &r;

	//printf("Storing: %s %f %ld \n" ,value->path, value->duration, value->fingerprints);

	pthread_mutex_lock(&olaf_db->shared->snapshots);
	int status = mdb_put(olaf_db->txn, olaf_db->dbi_resource_map, &mdb_key, &mdb_value,0);
	pthread_mutex_unlock(&olaf_db->shared->snapshots);
	e(status);
}

void olaf_db_delete_meta_data(Olaf_DB * olaf_db, uint32_t * key){
	MDB_val mdb_key, mdb_value;

	mdb_key.mv_size = sizeof(uint32_t);
	mdb_key.mv_data = key;

	Olaf_Resource_Meta_data r;
	
	mdb_value.mv_size = sizeof(Olaf_Resource_Meta_data);
	mdb_value.mv_data = &r;

	pthread_mutex_lock(&olaf_db->shared->snapshots);
	int status = mdb_del(olaf_db->txn, olaf_db->dbi_resource_map, &mdb_key, &mdb_value);
	pthread_mutex_unlock(&olaf_db->shared->snapshots);
	e(status);
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

		snprintf(value->path,sizeof(value->path),"%s",r.path);
		value->duration=r.duration;
		value->fingerprints = r.fingerprints;
		//printf("For key %u, meta data: '%s'  %ld %f \n",*key ,r.path,r.fingerprints,r.duration);
	}else if (result == MDB_NOTFOUND){
		printf("No meta data with key %u \n", *key);
	}
}

// Walk the resource-map cursor, aggregating per-song meta-data. When
// verbose is true the per-row detail is printed; the totals are always
// returned so both the printing path and the struct accessor share one walk.
static Olaf_DB_Stats olaf_db_stats_walk(Olaf_DB * olaf_db, bool verbose, bool print_rows){
	Olaf_DB_Stats stats = {0, 0.0f, 0};

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
		return stats;
	}

	if(print_rows){
		printf("  key  \tduration(s)\tPrints(#)\tPrints(#/s)\tpath\n");
	}
	//query
	do {
		uint32_t keyInt = *((uint32_t *) (mdb_key.mv_data));
		Olaf_Resource_Meta_data val = *((Olaf_Resource_Meta_data *) (mdb_value.mv_data));

		float fps_per_second =  (float) val.fingerprints / val.duration;

		stats.total_duration += val.duration;
		stats.total_fingerprints += val.fingerprints;
		stats.song_count += 1;

		if(print_rows && verbose){
			printf("%12u\t%.3fs\t%6ldfps\t%.3ffps/s\t'%s'\n",keyInt,val.duration,val.fingerprints,fps_per_second,val.path);
		}

		rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT);

	} while (rc == 0);

	return stats;
}

Olaf_DB_Stats olaf_db_stats_struct(Olaf_DB * olaf_db){
	return olaf_db_stats_walk(olaf_db, false, false);
}

void olaf_db_stats_meta_data(Olaf_DB * olaf_db,bool verbose){
	Olaf_DB_Stats stats = olaf_db_stats_walk(olaf_db, verbose, true);

	if(stats.song_count == 0){
		printf("Number of songs (#):\t%u\n",0);
		printf("Total duration (s):\t%.3f\n",0.0f);
		printf("Avg prints/s (fp/s):\t%.3f\n",0.0f);
		return;
	}

	float fps_per_second =  (float) stats.total_fingerprints / stats.total_duration;

	printf("Number of songs (#):\t%u\n",stats.song_count);
	printf("Total duration (s):\t%.3f\n",stats.total_duration);
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
	pthread_mutex_lock(&olaf_db->shared->snapshots);
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
	pthread_mutex_unlock(&olaf_db->shared->snapshots);
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
	size_t size = strlen(olaf_db->mdb_folder) + sizeof("/data.mdb");
	char *path = malloc(size);
	if(!path) return 0;
	//Inspect the file without opening/closing an additional DB descriptor.
	size_t bytes = 0;
#ifdef _WIN32
	snprintf(path,size,"%s\\data.mdb",olaf_db->mdb_folder);
	WIN32_FILE_ATTRIBUTE_DATA info;
	if(GetFileAttributesExA(path,GetFileExInfoStandard,&info))
		bytes = (size_t) (((uint64_t) info.nFileSizeHigh << 32) | info.nFileSizeLow);
#else
	snprintf(path,size,"%s/data.mdb",olaf_db->mdb_folder);
	struct stat info;
	if(stat(path,&info) == 0 && info.st_size >= 0) bytes = (size_t) info.st_size;
#endif
	free(path);
	return bytes;
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
		printf("%12"PRIu64"\t%12"PRIu64": [%8d,%8d]\n",number_of_fps,hash,ref_id,ref_t1);
		
		rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT_DUP );
		if(rc == MDB_NOTFOUND ){
			rc = mdb_cursor_get(cursor, &mdb_key, &mdb_value, MDB_NEXT);
		}
	} while (rc == 0);
	printf("Total fingerprints:\t%"PRIu64"\n",number_of_fps);
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

//End the transaction before releasing its environment reference.
void olaf_db_destroy(Olaf_DB * olaf_db){
	int status = 0;
	if(olaf_db->readonly){
		pthread_mutex_lock(&olaf_db->shared->snapshots);
		mdb_txn_abort(olaf_db->txn);
		pthread_mutex_unlock(&olaf_db->shared->snapshots);
	}else{
		pthread_mutex_lock(&olaf_db->shared->snapshots);
		status = mdb_txn_commit(olaf_db->txn);
		pthread_mutex_unlock(&olaf_db->shared->snapshots);
		pthread_mutex_unlock(&olaf_db->shared->writer);
	}
	//Commit consumes the transaction even on failure; never abort it again.
	if(status) fprintf(stderr,"Database commit failed for '%s'\n",olaf_db->mdb_folder);
	olaf_db_environment_release(olaf_db->shared);
	free(olaf_db);
	e_ctx(status,"mdb_txn_commit",NULL);
}
