#ifndef OLAF_WRAPPER_BRIDGE_H
#define OLAF_WRAPPER_BRIDGE_H

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

// Check if audio files exist in the database and print metadata
void olaf_has(const Olaf_Config* config,size_t audio_identifiers_len,const char* audio_identifiers[],bool * has_audio_identifier);

// Store fingerprints from CSV files using cache and exit
int olaf_store_cached(int argc, const char* argv[]);

// Main entry point for Olaf CLI bridge
int olaf_main(int argc, const char* argv[]);


#endif // OLAF_WRAPPER_BRIDGE_H