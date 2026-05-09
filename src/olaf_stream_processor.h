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

/**
 * @file olaf_stream_processor.h
 *
 * @brief Makes it more easy to process an audio stream.
 * 
 * The stream processor 
 *
 */

#ifndef OLAF_STREAM_PROCESSOR_H
#define OLAF_STREAM_PROCESSOR_H

    #include "olaf_config.h"
    #include "olaf_runner.h"
    #include "olaf_fp_matcher.h"
    
    /**
     * @struct Olaf_Stream_Processor
     * @brief An opaque struct with state information related to the stream processor.
     * 
     */
    /** @typedef Olaf_Stream_Processor
     *  @brief Typedef for struct Olaf_Stream_Processor.
     */
    typedef struct Olaf_Stream_Processor Olaf_Stream_Processor;

    /**
     * @brief      Initialize a new stream processor.
     *
     * @param      runner     The runner which determines the type of processing to take place (query, match, print,... )
     * @param[in]  raw_path   The path to the transcoded raw audio samples file 
     * @param[in]  orig_path  The original audio path to store in meta-data.
     *
     * @return     Newly created state information related to the processor.
     */
    Olaf_Stream_Processor * olaf_stream_processor_new(Olaf_Runner * runner,const char* raw_path,const char* orig_path);

    /**
     * @brief      Process a file from the first to last audio sample.
     *
     * @param      olaf_stream_processor  The olaf stream processor.
     */
    void olaf_stream_processor_process(Olaf_Stream_Processor * olaf_stream_processor);

    /**
     * @brief      Free up memory and release resources.
     *
     * @param      olaf_stream_processor  The olaf stream processor.
     */
    void olaf_stream_processor_destroy(Olaf_Stream_Processor * olaf_stream_processor);

    /**
	 * @brief      Set the result callback function.
	 *
	 * @param      olaf_stream_processor  The stream processor
	 * @param      callback    The callback function
	 */
	void olaf_stream_processor_set_result_callback(Olaf_Stream_Processor * olaf_stream_processor,Olaf_FP_Matcher_Result_Callback callback);


    /**
     * @brief      Set the result header for the stream processor.
     * @param      processor   The stream processor
     * @param      result_header  The result header string
     */
    void olaf_stream_processor_set_result_header(Olaf_Stream_Processor * processor,const char * result_header);

    /** Total audio duration (seconds) consumed during the last process() call. */
    double olaf_stream_processor_audio_duration(Olaf_Stream_Processor * processor);

    /** CPU time (seconds) spent in the last process() call. */
    double olaf_stream_processor_cpu_time(Olaf_Stream_Processor * processor);

    /** Total fingerprints extracted during the last process() call. */
    size_t olaf_stream_processor_total_fingerprints(Olaf_Stream_Processor * processor);

    /**
     * Suppress the human-readable summary line normally printed to stderr at
     * end of process(). Use this when an alternative formatter (e.g. JSON)
     * needs deterministic output free of stderr chatter.
     */
    void olaf_stream_processor_set_suppress_summary(Olaf_Stream_Processor * processor, bool suppress);


#endif // OLAF_STREAM_PROCESSOR_H
