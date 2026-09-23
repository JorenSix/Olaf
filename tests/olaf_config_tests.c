/* Deliberately use checks which remain active with NDEBUG. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "olaf_config_internal.h"
#include "olaf_fft.h"
#include "olaf_reader.h"
#include "olaf_runner.h"
#include "olaf_stream_processor.h"

#define CHECK(condition) do { if(!(condition)){ fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); exit(1); } } while(0)

static int fail_at = -1;
static int allocations;
static void * live[4096];
static size_t live_count;

static int should_fail(void){ return allocations++ == fail_at; }
static void * track(void * p){
	if(p){ CHECK(live_count < 4096); live[live_count++] = p; }
	return p;
}
void * olaf_test_malloc(size_t size){ return should_fail() ? NULL : track(malloc(size)); }
void * olaf_test_calloc(size_t count, size_t size){ return should_fail() ? NULL : track(calloc(count, size)); }
char * olaf_test_strdup(const char * text){
	char * p = olaf_test_malloc(strlen(text) + 1);
	if(p) memcpy(p, text, strlen(text) + 1);
	return p;
}
void olaf_test_free(void * pointer){
	if(!pointer) return;
	size_t i = 0;
	while(i < live_count && live[i] != pointer) i++;
	CHECK(i < live_count);
	live[i] = live[--live_count];
	free(pointer);
}

extern float olaf_ep_extractor_max_filter_time(float * array, size_t size);

static void boundaries(Olaf_Config base, const char * path){
	Olaf_Config c;
#define INVALID(field, value) do { c = base; c.field = value; CHECK(olaf_config_error(&c) != NULL); errno = 0; CHECK(olaf_runner_new(OLAF_RUNNER_MODE_PRINT, &c, NULL, NULL) == NULL); CHECK(errno == EINVAL); CHECK(live_count == 0); } while(0)
	INVALID(audioBlockSize, 2048);
	INVALID(audioBlockSize, 0);
	INVALID(audioStepSize, 0);
	INVALID(audioStepSize, 1025);
	INVALID(audioSampleRate, 0);
	INVALID(bytesPerAudioSample, 8);
	INVALID(maxEventPoints, 0);
	INVALID(eventPointThreshold, -1);
	INVALID(eventPointThreshold, base.maxEventPoints);
	INVALID(filterSizeTime, 1);
	INVALID(halfFilterSizeTime, 0);
	INVALID(filterSizeFrequency, 0);
	INVALID(halfFilterSizeFrequency, 0);
	INVALID(minFrequencyBin, -1);
	INVALID(minFrequencyBin, 512);
	INVALID(numberOfEPsPerFP, 4);
	INVALID(maxEventPointUsages, 0);
	INVALID(maxEventPointUsages, INT_MAX);
	INVALID(minTimeDistance, 0);
	INVALID(minTimeDistance, base.maxTimeDistance + 1);
	INVALID(minFreqDistance, -1);
	INVALID(minFreqDistance, base.maxFreqDistance + 1);
	INVALID(maxFingerprints, 0);
	INVALID(maxFingerprints, SIZE_MAX);
	INVALID(maxResults, 0);
	INVALID(maxResults, SIZE_MAX);
	INVALID(maxDBCollisions, 0);
	INVALID(maxDBCollisions, SIZE_MAX);
	INVALID(searchRange, -1);
	INVALID(minMatchCount, 0);
	INVALID(minEventPointMagnitude, NAN);
	INVALID(minMatchTimeDiff, INFINITY);
	INVALID(keepMatchesFor, -1);
	INVALID(printResultEvery, INFINITY);
	INVALID(keepMatchesFor, (float)INT_MAX);
#undef INVALID
	CHECK(olaf_reader_new(NULL, path) == NULL && errno == EINVAL);
	CHECK(olaf_fft_new(NULL) == NULL && errno == EINVAL);
	CHECK(olaf_ep_extractor_new(NULL) == NULL && errno == EINVAL);
	CHECK(olaf_fp_extractor_new(NULL) == NULL && errno == EINVAL);
	CHECK(olaf_fp_matcher_new(NULL, NULL, NULL) == NULL && errno == EINVAL);
	CHECK(olaf_stream_processor_new(NULL, path, "test") == NULL && errno == EINVAL);
	c = base; c.audioStepSize = 0;
	CHECK(olaf_reader_new(&c, "/missing/audio.raw") == NULL && errno == EINVAL);
	c = base; c.maxResults = 0; c.audioBlockSize = 16; c.audioStepSize = 16;
	Olaf_Reader * reader = olaf_reader_new(&c, path);
	CHECK(reader != NULL); /* unrelated matcher and pipeline settings do not apply */
	olaf_reader_destroy(reader);
	c = base; c.audioStepSize = 1; c.audioSampleRate = INT_MAX; c.keepMatchesFor = 1;
	CHECK(olaf_config_error(&c) == NULL);
	CHECK(olaf_config_duration_blocks(c.keepMatchesFor, &c) == INT_MAX);
	c.keepMatchesFor = nextafterf(1, 2);
	CHECK(olaf_config_error(&c) != NULL);
	c = base; c.keepMatchesFor = 0.012f;
	CHECK(olaf_config_duration_blocks(c.keepMatchesFor, &c) == 1);
	c.maxEventPoints = 1; c.eventPointThreshold = 0; c.minFrequencyBin = 511;
	c.maxFingerprints = 1; c.maxEventPointUsages = INT_MAX - 1;
	c.maxResults = 1; c.maxDBCollisions = 1; c.numberOfEPsPerFP = 2;
	CHECK(olaf_config_error(&c) == NULL);
	CHECK(live_count == 0);
	c = base; c.filterSizeTime = INT_MAX; c.halfFilterSizeTime = INT_MAX / 2;
	if(olaf_config_ep_error(&c) == NULL){
		/* Cleanup must not scan billions of rows that were never allocated. */
		allocations = 0; fail_at = 1;
		CHECK(olaf_ep_extractor_new(&c) == NULL && errno == ENOMEM);
		fail_at = -1;
		CHECK(live_count == 0);
	}
}

static void filters(Olaf_Config base){
	const int sizes[] = {2, 3, 4, 13, 24};
	for(size_t i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++){
		base.filterSizeTime = sizes[i];
		base.halfFilterSizeTime = sizes[i]/2;
		float * values = malloc(sizes[i] * sizeof(float));
		CHECK(values != NULL);
		for(int peak = 0; peak < sizes[i]; peak++){
			for(int j = 0; j < sizes[i]; j++) values[j] = j == peak ? 7 : -2;
			CHECK(olaf_ep_extractor_max_filter_time(values, sizes[i]) == 7);
		}
		free(values);
		Olaf_EP_Extractor * ep = olaf_ep_extractor_new(&base);
		CHECK(ep != NULL);
		float spectrum[1024] = {0};
		for(int block = 0; block < sizes[i] + 3; block++){
			struct extracted_event_points * points = olaf_ep_extractor_extract(ep, spectrum, block);
			CHECK(points->eventPointIndex == 0);
		}
		olaf_ep_extractor_destroy(ep);
		CHECK(live_count == 0);
	}
}

/* Fail each successive allocation, including nested FFT/hash-table allocations.
 * A clean success marks the end of that constructor's allocation sequence. */
static void allocation_failures(Olaf_Config * config, const char * path){
	for(int kind = 0; kind < 11; kind++){
		int successful = 0;
		for(int failure = 0; failure < 256; failure++){
			Olaf_Runner parent = {0};
			parent.config = config;
			parent.mode = OLAF_RUNNER_MODE_QUERY;
			allocations = 0; fail_at = failure; errno = 0;
			void * object = NULL;
			switch(kind){
				case 0: object = olaf_config_default(); break;
				case 1: object = olaf_config_test(); break;
				case 2: object = olaf_config_esp_32(); break;
				case 3: object = olaf_config_mem(); break;
				case 4: object = olaf_fft_new(config); break;
				case 5: object = olaf_ep_extractor_new(config); break;
				case 6: object = olaf_fp_extractor_new(config); break;
				case 7: object = olaf_fp_matcher_new(config, NULL, NULL); break;
				case 8: object = olaf_reader_new(config, path); break;
				case 9: object = olaf_runner_new(OLAF_RUNNER_MODE_PRINT, config, NULL, NULL); break;
				case 10: object = olaf_stream_processor_new(&parent, path, "test"); break;
			}
			int error = errno;
			fail_at = -1;
			if(object){
				switch(kind){
					case 0: case 1: case 2: case 3: olaf_config_destroy(object); break;
					case 4: olaf_fft_destroy(object); break;
					case 5: olaf_ep_extractor_destroy(object); break;
					case 6: olaf_fp_extractor_destroy(object); break;
					case 7: olaf_fp_matcher_destroy(object); break;
					case 8: olaf_reader_destroy(object); break;
					case 9: olaf_runner_destroy(object); break;
					case 10: olaf_stream_processor_destroy(object); break;
				}
				successful = 1;
			}else CHECK(error == ENOMEM);
			CHECK(live_count == 0);
			if(successful) break;
		}
		CHECK(successful);
	}
}

int main(int argc, char ** argv){
	CHECK(argc == 2);
	Olaf_Config * presets[] = {olaf_config_default(), olaf_config_test(), olaf_config_esp_32(), olaf_config_mem()};
	for(size_t i = 0; i < 4; i++){ CHECK(presets[i] != NULL); CHECK(olaf_config_error(presets[i]) == NULL); }
	Olaf_Config base = *presets[0];
	base.dbFolder = NULL;
	for(size_t i = 0; i < 4; i++) olaf_config_destroy(presets[i]);
	CHECK(live_count == 0);
	boundaries(base, argv[1]);
	filters(base);
	allocation_failures(&base, argv[1]);
	puts("configuration safety tests passed");
	return 0;
}
