
// Standard types that CFFI needs defined
typedef ... FILE;
typedef unsigned char bool;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef unsigned short uint16_t;
typedef unsigned char uint8_t;
typedef int int32_t;
typedef long long int64_t;
typedef short int16_t;
typedef signed char int8_t;
typedef unsigned long size_t;

// Python callback for results
extern "Python" void olaf_python_wrapper_handle_result(
    int matchCount,
    float queryStart,
    float queryStop,
    const char* path,
    uint32_t matchIdentifier,
    float referenceStart,
    float referenceStop
);

	typedef struct Olaf_Config Olaf_Config;
	struct Olaf_Config{
		char * dbFolder;
		int audioBlockSize;
		int audioSampleRate;
		int audioStepSize;
		int bytesPerAudioSample;
		bool verbose;
		int maxEventPointsPerBlock;
		int filterSizeTime;
		int halfFilterSizeTime;
		int filterSizeFrequency;
		int halfFilterSizeFrequency;
		float minEventPointMagnitude;
		int minFrequencyBin;
		int maxEventPointUsages;
		int maxEventPoints;
		int eventPointThreshold;
		bool sqrtMagnitude;
		bool useMagnitudeInfo;
		int numberOfEPsPerFP;
		int minTimeDistance;
		int maxTimeDistance;
		int minFreqDistance;
		int maxFreqDistance;
		size_t maxFingerprints;
		size_t maxResults;
		int searchRange;
		int minMatchCount;
		float minMatchTimeDiff;
		float keepMatchesFor;
		float printResultEvery;
		size_t maxDBCollisions;
	};
	Olaf_Config* olaf_config_default(void);
	Olaf_Config* olaf_config_test(void);
	Olaf_Config* olaf_config_esp_32(void);
	Olaf_Config* olaf_config_mem(void);
	void olaf_config_destroy(Olaf_Config *config);

	typedef struct Olaf_Resource_Meta_data Olaf_Resource_Meta_data;
    struct Olaf_Resource_Meta_data{
		float duration;
		long fingerprints;
		char path[512];
	};

	struct eventpoint {
		int frequencyBin;
		int timeIndex;
		float magnitude;
		int usages;
	};
	struct extracted_event_points{
		struct eventpoint * eventPoints;
		int eventPointIndex;
	};
	typedef struct Olaf_EP_Extractor Olaf_EP_Extractor;
	Olaf_EP_Extractor * olaf_ep_extractor_new(Olaf_Config * config);
	void olaf_ep_extractor_print_ep(struct eventpoint);
	struct extracted_event_points * olaf_ep_extractor_extract(Olaf_EP_Extractor * olaf_ep_extractor, float* fft_magnitudes, int audioBlockIndex);
	float * olaf_ep_extractor_mags(Olaf_EP_Extractor * olaf_ep_extractor);
	void olaf_ep_extractor_destroy(Olaf_EP_Extractor * olaf_ep_extractor );

	struct fingerprint{
		int frequencyBin1;
		int timeIndex1;
		float magnitude1;
		int frequencyBin2;
		int timeIndex2;
		float magnitude2;
		int frequencyBin3;
		int timeIndex3;
		float magnitude3;
	};
	struct extracted_fingerprints{
		struct fingerprint * fingerprints;
		size_t fingerprintIndex;
	};
	typedef struct Olaf_FP_Extractor Olaf_FP_Extractor;
	Olaf_FP_Extractor * olaf_fp_extractor_new(Olaf_Config * config);
	void olaf_fp_extractor_destroy(Olaf_FP_Extractor * olaf_fp_extractor);
	struct extracted_fingerprints * olaf_fp_extractor_extract(Olaf_FP_Extractor * olaf_fp_extractor,struct extracted_event_points * eps,int audioBlockIndex);
	size_t olaf_fp_extractor_total(Olaf_FP_Extractor * fp_extractor);
	uint64_t olaf_fp_extractor_hash(struct fingerprint f);
	void olaf_fp_extractor_print(struct fingerprint f);

	typedef struct Olaf_DB Olaf_DB;
	Olaf_DB * olaf_db_new(const char * db_file_folder,bool readonly);
	void olaf_db_destroy(Olaf_DB * db);
	void olaf_db_store_meta_data(Olaf_DB * db, uint32_t * key, Olaf_Resource_Meta_data * value);
	void olaf_db_find_meta_data(Olaf_DB * db , uint32_t * key, Olaf_Resource_Meta_data * value);
	void olaf_db_delete_meta_data(Olaf_DB * db , uint32_t * key);
	bool olaf_db_has_meta_data(Olaf_DB * db , uint32_t * key);
	void olaf_db_stats_meta_data(Olaf_DB * db,bool verbose);
	void olaf_db_store(Olaf_DB * db, uint64_t * keys, uint64_t * values, size_t size);
	void olaf_db_delete(Olaf_DB * db, uint64_t * keys, uint64_t * values, size_t size);
	size_t olaf_db_find(Olaf_DB * db,uint64_t start_key,uint64_t stop_key,uint64_t * results, size_t results_size);
	bool olaf_db_find_single(Olaf_DB * db,uint64_t start_key,uint64_t stop_key);
	void olaf_db_stats(Olaf_DB * db,bool verbose);
	uint32_t olaf_db_string_hash(const char *key, size_t len);

	typedef void (*Olaf_FP_Matcher_Result_Callback)(int matchCount, float queryStart, float queryStop, const char* path, uint32_t matchIdentifier, float referenceStart, float referenceStop);
	typedef struct Olaf_FP_Matcher Olaf_FP_Matcher;
	Olaf_FP_Matcher * olaf_fp_matcher_new(Olaf_Config * config,Olaf_DB* db,Olaf_FP_Matcher_Result_Callback callback );
 	void olaf_fp_matcher_match(Olaf_FP_Matcher * olaf_fp_matcher, struct extracted_fingerprints * olaf_fps);
	void olaf_fp_matcher_print_header(Olaf_FP_Matcher * fp_matcher);
	void olaf_fp_matcher_callback_print_result(int matchCount, float queryStart, float queryStop, const char* path, uint32_t matchIdentifier, float referenceStart, float referenceStop);
	void olaf_fp_matcher_print_results(Olaf_FP_Matcher * olaf_fp_matcher);
	void olaf_fp_matcher_destroy(Olaf_FP_Matcher * olaf_fp_matcher);
	void olaf_fp_matcher_set_header(Olaf_FP_Matcher * fp_matcher, const char * header);

	typedef struct Olaf_FP_DB_Writer Olaf_FP_DB_Writer;
	Olaf_FP_DB_Writer * olaf_fp_db_writer_new(Olaf_DB* db,uint32_t audio_file_identifier);
	void olaf_fp_db_writer_store( Olaf_FP_DB_Writer * olaf_fp_db_writer, struct extracted_fingerprints * fingerprints);
	void olaf_fp_db_writer_delete( Olaf_FP_DB_Writer * olaf_fp_db_writer, struct extracted_fingerprints * fingerprints);
	void olaf_fp_db_writer_destroy(Olaf_FP_DB_Writer * olaf_fp_db_writer, bool store);

	typedef struct Olaf_FFT Olaf_FFT;
	Olaf_FFT * olaf_fft_new(Olaf_Config * config);
	void olaf_fft_forward(Olaf_FFT * olaf_fft, float * audio_data);
	void olaf_fft_destroy(Olaf_FFT * olaf_fft );

