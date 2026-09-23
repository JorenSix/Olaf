#ifndef OLAF_CONFIG_INTERNAL_H
#define OLAF_CONFIG_INTERNAL_H

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include "olaf_config.h"
#include "olaf_fp_extractor.h"

/* Private constructor checks. Validate only the fields a component consumes. */
#define OLAF_REQUIRE(condition, message) do { if(!(condition)) return message; } while(0)

static inline const char * olaf_config_audio_error(const Olaf_Config * c){
	OLAF_REQUIRE(c != NULL, "config must not be NULL");
	OLAF_REQUIRE(c->audioBlockSize > 0 && (size_t)c->audioBlockSize <= SIZE_MAX / sizeof(float), "audioBlockSize must be positive and fit an audio buffer");
	OLAF_REQUIRE(c->bytesPerAudioSample == 4 && sizeof(float) == 4, "bytesPerAudioSample must be 4");
	OLAF_REQUIRE(c->audioStepSize >= 1 && c->audioStepSize <= c->audioBlockSize, "audioStepSize must be between 1 and audioBlockSize");
	OLAF_REQUIRE(c->audioSampleRate > 0, "audioSampleRate must be positive");
	return NULL;
}

static inline const char * olaf_config_fft_error(const Olaf_Config * c){
	const char * error = olaf_config_audio_error(c);
	if(error) return error;
	OLAF_REQUIRE(c->audioBlockSize == 1024, "audioBlockSize must be 1024 for the extraction pipeline");
	return NULL;
}

static inline const char * olaf_config_ep_error(const Olaf_Config * c){
	const char * error = olaf_config_fft_error(c);
	if(error) return error;
	OLAF_REQUIRE(c->maxEventPoints > 0 && (size_t)c->maxEventPoints <= SIZE_MAX / sizeof(struct eventpoint), "maxEventPoints must be positive and fit an event point buffer");
	OLAF_REQUIRE(c->eventPointThreshold >= 0 && c->eventPointThreshold < c->maxEventPoints, "eventPointThreshold must be nonnegative and below maxEventPoints");
	OLAF_REQUIRE(c->filterSizeTime >= 2 && (size_t)c->filterSizeTime <= SIZE_MAX / sizeof(float *) && (size_t)c->filterSizeTime <= SIZE_MAX / sizeof(float), "filterSizeTime must be at least 2 and fit filter buffers");
	OLAF_REQUIRE(c->halfFilterSizeTime == c->filterSizeTime / 2, "halfFilterSizeTime must equal filterSizeTime / 2");
	OLAF_REQUIRE(c->filterSizeFrequency > 0, "filterSizeFrequency must be positive");
	OLAF_REQUIRE(c->halfFilterSizeFrequency == c->filterSizeFrequency / 2, "halfFilterSizeFrequency must equal filterSizeFrequency / 2");
	OLAF_REQUIRE(c->minFrequencyBin >= 0 && c->minFrequencyBin < c->audioBlockSize / 2, "minFrequencyBin must be within the magnitude buffer");
	OLAF_REQUIRE(isfinite(c->minEventPointMagnitude) && c->minEventPointMagnitude >= 0, "minEventPointMagnitude must be finite and nonnegative");
	return NULL;
}

static inline const char * olaf_config_fp_error(const Olaf_Config * c){
	OLAF_REQUIRE(c != NULL, "config must not be NULL");
	OLAF_REQUIRE(c->maxEventPoints > 0 && (size_t)c->maxEventPoints <= SIZE_MAX / sizeof(struct eventpoint), "maxEventPoints must be positive and fit an event point buffer");
	OLAF_REQUIRE(c->numberOfEPsPerFP == 2 || c->numberOfEPsPerFP == 3, "numberOfEPsPerFP must be 2 or 3");
	OLAF_REQUIRE(c->minTimeDistance >= 1 && c->maxTimeDistance >= c->minTimeDistance, "minTimeDistance must be positive and at most maxTimeDistance");
	OLAF_REQUIRE(c->minFreqDistance >= 0 && c->maxFreqDistance >= c->minFreqDistance, "minFreqDistance must be nonnegative and at most maxFreqDistance");
	OLAF_REQUIRE(c->maxFingerprints > 0 && c->maxFingerprints <= SIZE_MAX / sizeof(struct fingerprint), "maxFingerprints must be positive and fit a fingerprint buffer");
	OLAF_REQUIRE(c->maxEventPointUsages > 0 && c->maxFingerprints <= (size_t)(INT_MAX - c->maxEventPointUsages), "maxEventPointUsages plus maxFingerprints must fit int");
	return NULL;
}

static inline int olaf_config_duration_blocks(float seconds, const Olaf_Config * c){
	return (int)((double)seconds * c->audioSampleRate / c->audioStepSize);
}

static inline const char * olaf_config_matcher_error(const Olaf_Config * c){
	OLAF_REQUIRE(c != NULL, "config must not be NULL");
	OLAF_REQUIRE(c->audioSampleRate > 0 && c->audioStepSize > 0, "audioSampleRate and audioStepSize must be positive");
	OLAF_REQUIRE(c->maxResults > 0 && c->maxResults <= SIZE_MAX / sizeof(void *), "maxResults must be positive and fit a results buffer");
	OLAF_REQUIRE(c->maxDBCollisions > 0 && c->maxDBCollisions <= SIZE_MAX / sizeof(uint64_t), "maxDBCollisions must be positive and fit a collision buffer");
	OLAF_REQUIRE(c->searchRange >= 0, "searchRange must be nonnegative");
	OLAF_REQUIRE(c->minMatchCount >= 1, "minMatchCount must be positive");
	OLAF_REQUIRE(isfinite(c->minMatchTimeDiff) && c->minMatchTimeDiff >= 0, "minMatchTimeDiff must be finite and nonnegative");
	OLAF_REQUIRE(isfinite(c->keepMatchesFor) && c->keepMatchesFor >= 0 && (double)c->keepMatchesFor * c->audioSampleRate / c->audioStepSize <= INT_MAX, "keepMatchesFor must be finite, nonnegative and fit int blocks");
	OLAF_REQUIRE(isfinite(c->printResultEvery) && c->printResultEvery >= 0 && (double)c->printResultEvery * c->audioSampleRate / c->audioStepSize <= INT_MAX, "printResultEvery must be finite, nonnegative and fit int blocks");
	return NULL;
}

static inline const char * olaf_config_error(const Olaf_Config * c){
	const char * error = olaf_config_ep_error(c);
	if(!error) error = olaf_config_fp_error(c);
	if(!error) error = olaf_config_matcher_error(c);
	return error;
}

static inline int olaf_config_check(const char * error){
	if(!error) return 1;
	fprintf(stderr, "Invalid Olaf configuration: %s\n", error);
	errno = EINVAL;
	return 0;
}
#undef OLAF_REQUIRE
#endif
