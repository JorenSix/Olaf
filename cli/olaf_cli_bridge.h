#ifndef OLAF_CLI_BRIDGE_H
#define OLAF_CLI_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#include "olaf_config.h"
#include "olaf_db.h"


// Print database statistics
int olaf_stats(const Olaf_Config* config);

// Aggregate database statistics into a struct instead of printing them.
// Returns 0 on success, -1 if the db folder is misconfigured. On success
// `*out` is filled; on the empty-db case the struct is zeroed.
int olaf_stats_struct(const Olaf_Config* config, Olaf_DB_Stats* out);

// A single query match, returned (not printed) by olaf_query_collect.
typedef struct {
	int match_count;
	float query_start;
	float query_stop;
	uint32_t match_identifier;
	float reference_start;
	float reference_stop;
	char path[512];
} Olaf_Query_Match;

// Run a query and write matches into the caller-provided `out` array
// (capacity `max_matches`). Returns the number of matches written, which
// may be less than the true count if the buffer is too small. No stdout
// output is produced.
size_t olaf_query_collect(Olaf_Config* config, const char * query_path, const char* raw_audio_path, const char* audio_identifier, uint32_t exclude_identifier, Olaf_Query_Match* out, size_t max_matches);


// Get the default Olaf configuration
Olaf_Config* olaf_default_config();

// store audio file in the database
// This function takes a raw audio file path and an audio identifier (e.g., original file name, or a unique identifier).
// It processes the audio file and stores the fingerprints in the database.
void olaf_store(Olaf_Config* config, const char* raw_audio_path, const char* audio_identifier);

// `exclude_identifier`: when non-zero, suppress result lines whose
// match_identifier equals this hash (used to filter self-matches in dedup).
// Pass 0 for no filtering.
void olaf_query(Olaf_Config* config, size_t q_index, size_t q_total, const char * query_path, const char* raw_audio_path, const char* audio_identifier, uint32_t exclude_identifier);

// Same as olaf_query but prints a single JSON object per query to stdout
// (instead of CSV lines) and suppresses the human-readable summary on stderr.
void olaf_query_json(Olaf_Config* config, size_t q_index, size_t q_total, const char * query_path, const char* raw_audio_path, const char* audio_identifier, uint32_t exclude_identifier);

// Delete fingerprints from the database by audio identifier
void olaf_delete(Olaf_Config* config, const char* raw_audio_path, const char* audio_identifier);

// Print fingerprints to a specified file
void olaf_print_to_file(Olaf_Config* config, const char* raw_audio_path, const char* audio_identifier,FILE * fp_cache_file, FILE * fp_meta_file);

// Print fingerprints to stdout (for caching)
void olaf_print(Olaf_Config* config, const char* raw_audio_path, const char* audio_identifier);

// Get audio identifier hash from filename
uint32_t olaf_name_to_id(const char* audio_identifier);

// Check if audio files exist in the database and print metadata
void olaf_has(Olaf_Config* config,size_t audio_identifiers_len,const char* audio_identifiers[],bool * has_audio_identifier);

// Store fingerprints from CSV files using cache and exit
int olaf_store_cached(int argc, const char* argv[]);

// Main entry point for Olaf CLI bridge
int olaf_main(int argc, const char* argv[]);


#endif // OLAF_CLI_BRIDGE_H