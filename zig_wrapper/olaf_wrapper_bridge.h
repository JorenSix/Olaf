#ifndef OLAF_WRAPPER_BRIDGE_H
#define OLAF_WRAPPER_BRIDGE_H



// Print help message and exit
void olaf_print_help(const char* message);

// Print database statistics and exit
int olaf_stats(void);

// Check if audio files exist in the database and print metadata
int olaf_has(int argc, const char* argv[]);

// Store fingerprints from CSV files using cache and exit
int olaf_store_cached(int argc, const char* argv[]);

// Main entry point for Olaf CLI bridge
int olaf_main(int argc, const char* argv[]);


#endif // OLAF_WRAPPER_BRIDGE_H