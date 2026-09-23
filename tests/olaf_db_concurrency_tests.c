/* Synthetic DB tests. No audio, public API changes, or inherited LMDB handles. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif
#include "olaf_db.h"

const void *olaf_db_test_environment(Olaf_DB *db);
size_t olaf_db_test_environment_count(void);

static void *watchdog(void *unused){
	(void) unused;
#ifdef _WIN32
	Sleep(30000);
#else
	sleep(30);
#endif
	fputs("database safety test timed out\n",stderr);
	abort();
}

static void put(Olaf_DB *db,uint32_t id){
	uint64_t key = id, value = ((uint64_t) id << 32) | id;
	olaf_db_store(db,&key,&value,1);
	Olaf_Resource_Meta_data meta = {0};
	snprintf(meta.path,sizeof(meta.path),"record-%u",id);
	meta.duration = id;
	meta.fingerprints = 1;
	olaf_db_store_meta_data(db,&id,&meta);
}

static void check(Olaf_DB *db,uint32_t id,bool present){
	assert(olaf_db_has_meta_data(db,&id) == present);
	uint64_t value = 0;
	size_t count = olaf_db_find(db,id,id,&value,1);
	assert(count == (present ? 1 : 0));
	if(present){
		assert(value == (((uint64_t) id << 32) | id));
		Olaf_Resource_Meta_data meta = {0};
		olaf_db_find_meta_data(db,&id,&meta);
		assert(meta.duration == id && meta.fingerprints == 1);
		char path[64];
		snprintf(path,sizeof(path),"record-%u",id);
		assert(strcmp(meta.path,path) == 0);
	}
}

static void seed(const char *path){
	Olaf_DB *db = olaf_db_new(path,false);
	put(db,1);
	olaf_db_destroy(db);
	assert(olaf_db_test_environment_count() == 0);
}

struct Gate{
	pthread_mutex_t mutex;
	pthread_cond_t cond;
	unsigned arrived, generation, target;
};

static void gate(struct Gate *g){
	pthread_mutex_lock(&g->mutex);
	unsigned generation = g->generation;
	if(++g->arrived == g->target){
		g->arrived = 0;
		g->generation++;
		pthread_cond_broadcast(&g->cond);
	}else{
		while(generation == g->generation) pthread_cond_wait(&g->cond,&g->mutex);
	}
	pthread_mutex_unlock(&g->mutex);
}

struct Job{
	const char *path;
	struct Gate *gate;
	unsigned id;
	int mode;
	const void *env;
};

static void *worker(void *arg){
	struct Job *job = arg;
	gate(job->gate);
	if(job->mode == 0){
		Olaf_DB *db = olaf_db_new(job->path,true);
		job->env = olaf_db_test_environment(db);
		check(db,1,true);
		gate(job->gate); //all 32 read transactions remain open together
		olaf_db_destroy(db);
	}else if(job->mode == 1){
		Olaf_DB *db = olaf_db_new(job->path,false);
		put(db,100 + job->id);
		olaf_db_destroy(db);
	}else{
		for(int i = 0; i < 100; i++){
			bool write = job->mode == 3 && job->id % 2 == 0;
			Olaf_DB *db = olaf_db_new(job->path,!write);
			if(write) put(db,200 + job->id);
			else check(db,1,true);
			olaf_db_destroy(db);
		}
	}
	return NULL;
}

static void concurrent(const char *path,int mode){
	enum { N = 32 };
	struct Gate g = {PTHREAD_MUTEX_INITIALIZER,PTHREAD_COND_INITIALIZER,0,0,N};
	pthread_t threads[N];
	struct Job jobs[N];
	for(unsigned i = 0; i < N; i++){
		jobs[i] = (struct Job){path,&g,i,mode,NULL};
		assert(pthread_create(&threads[i],NULL,worker,&jobs[i]) == 0);
	}
	for(unsigned i = 0; i < N; i++) assert(pthread_join(threads[i],NULL) == 0);
	if(mode == 0){
		for(unsigned i = 1; i < N; i++) assert(jobs[i].env == jobs[0].env);
	}
	assert(olaf_db_test_environment_count() == 0);
	if(mode == 1){
		Olaf_DB *db = olaf_db_new(path,true);
		for(unsigned i = 0; i < N; i++) check(db,100 + i,true);
		olaf_db_destroy(db);
	}
	pthread_cond_destroy(&g.cond);
	pthread_mutex_destroy(&g.mutex);
}

static void all(const char *path,const char *other,const char *alias){
	seed(path);
	seed(other);
	char *owned = strdup(path);
	Olaf_DB *old = olaf_db_new(owned,true);
	free(owned);
	Olaf_DB *reader = olaf_db_new(alias,true);
	assert(olaf_db_test_environment(old) == olaf_db_test_environment(reader));
	assert(olaf_db_test_environment_count() == 1);
	olaf_db_destroy(reader);
	check(old,1,true);

	Olaf_DB *writer = olaf_db_new(path,false);
	assert(olaf_db_test_environment(old) == olaf_db_test_environment(writer));
	put(writer,2);
	//A second database must be writable while the first writer is active.
	Olaf_DB *independent = olaf_db_new(other,false);
	put(independent,3);
	olaf_db_destroy(independent);
	olaf_db_destroy(writer);
	check(old,2,false);
	reader = olaf_db_new(path,true);
	check(reader,2,true);
	olaf_db_destroy(old);
	check(reader,1,true);
	olaf_db_destroy(reader);
	assert(olaf_db_test_environment_count() == 0);
	concurrent(path,0);
	concurrent(path,1);
	concurrent(path,2);
	concurrent(path,3);
	puts("database concurrency tests passed");
}

int main(int argc,char **argv){
	assert(argc >= 3);
	pthread_t timeout;
	assert(pthread_create(&timeout,NULL,watchdog,NULL) == 0);
	pthread_detach(timeout);
	const char *mode = argv[1], *path = argv[2];
	if(strcmp(mode,"all") == 0){
		assert(argc == 5);
		all(path,argv[3],argv[4]);
	}else if(strcmp(mode,"seed") == 0){
		seed(path);
	}else if(strcmp(mode,"missing") == 0){
		olaf_db_destroy(olaf_db_new(path,true));
		abort(); //must fail rather than create data.mdb
	}else if(strcmp(mode,"reader") == 0){
		Olaf_DB *old = olaf_db_new(path,true);
		check(old,1,true);
		putchar('R'); fflush(stdout);
		assert(getchar() == 'C');
		check(old,1,true);
		check(old,2,false);
		Olaf_DB *fresh = olaf_db_new(path,true);
		check(fresh,1,false);
		check(fresh,2,true);
		olaf_db_destroy(old);
		olaf_db_destroy(fresh);
	}else if(strcmp(mode,"replace") == 0){
		Olaf_DB *db = olaf_db_new(path,false);
		uint32_t id = 1;
		uint64_t key = 1, value = ((uint64_t) 1 << 32) | 1;
		olaf_db_delete(db,&key,&value,1);
		olaf_db_delete_meta_data(db,&id);
		put(db,2);
		olaf_db_destroy(db);
		//Repeated writes exercise page reuse while another process holds a snapshot.
		for(int i = 0; i < 100; i++){
			db = olaf_db_new(path,false);
			for(uint32_t n = 10; n < 110; n++) put(db,n);
			olaf_db_destroy(db);
		}
	}else abort();
	assert(olaf_db_test_environment_count() == 0);
	return 0;
}
