#ifndef OLAF_CLI_BRIDGE_H
#define OLAF_CLI_BRIDGE_H

#include <stdint.h>

#include "olaf_config.h"


// Print database statistics
int olaf_stats(const Olaf_Config* config);


// Get the default Olaf configuration
Olaf_Config* olaf_default_config();

// store audio file in the database
// This function takes a raw audio file path and an audio identifier (e.g., original file name, or a unique identifier).
// It processes the audio file and stores the fingerprints in the database.
void olaf_store(Olaf_Config* config, const char* raw_audio_path, const char* audio_identifier);

void olaf_query(Olaf_Config* config, size_t q_index, size_t q_total, const char * query_path, const char* raw_audio_path, const char* audio_identifier);

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