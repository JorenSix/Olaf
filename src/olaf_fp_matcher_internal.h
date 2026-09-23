#ifndef OLAF_FP_MATCHER_INTERNAL_H
#define OLAF_FP_MATCHER_INTERNAL_H
#include "olaf_fp_matcher.h"
#include "hash-table.h"

/* Private state shared with the owning stream processor. Public headers keep
 * Olaf_FP_Matcher opaque; callback setup adds no exported API symbol. */
struct Olaf_FP_Matcher{

	struct match_result ** match_results;
	int max_age;
	int print_interval;
	HashTable *result_hash_table; /**< Hash table mapping match_id/time-diff combinations to match structs */

	Olaf_DB * db; /**< The database to use */

	Olaf_Config * config; /**< The configuration of Olaf */

	uint64_t * db_results; /**< List of results returned by the database, limited to maxDBCollisions */

	Olaf_FP_Matcher_Result_Callback result_callback; /**< Callback invoked for each match result */

	const char * header; /**< Optional header string for result output */

	int last_print_at; /**< Audio block index of the last printed result */
};

static inline void olaf_fp_matcher_set_callback_internal(Olaf_FP_Matcher * fp_matcher, Olaf_FP_Matcher_Result_Callback callback){
	fp_matcher->result_callback = callback;
}
#endif
