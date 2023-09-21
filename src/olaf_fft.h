

#ifndef OLAF_FFT_H
#define OLAF_FFT_H

#include "olaf_config.h"

	/**
     * @struct Olaf_FFT
     * @brief An opaque struct with state information related to the fft.
     * 
     */
	typedef struct Olaf_FFT Olaf_FFT;

	/**
	 * Initialize a new @ref Olaf_FFT struct according to the given configuration.
	 * @param config The configuration currenlty in use.
	 * @return An initialized @ref Olaf_FFT struct or undefined if memory could not be allocated.
	 */
	Olaf_FFT * olaf_fft_new(Olaf_Config * config);

	/**
	 * Calculate a forwards FFT for an audio block, a window is applied automatically.
	 * @param olaf_fft The fft struct with state info
	 * @param audio_data The audio data, it also serves as fft output. Once done the audio_data is replaced by interleaved complex numbers representing the fft.
	 */
	void olaf_fft_forward(Olaf_FFT * olaf_fft, float * audio_data);

	/**
	 * Free memory or other resources.
	 * @param  olaf_fft The FFT object to destroy.
	 */ 
	void olaf_fft_destroy(Olaf_FFT * olaf_fft );

#endif // OLAF_FFT_H
