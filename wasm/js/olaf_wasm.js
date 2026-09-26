// Loads the Olaf WebAssembly module (wasm/js/olaf.wasm, built with `zig build web`).
// Shared by the AudioWorklet (olaf_processor.js) and the node test (../olaf_wasm_test.mjs).

// Samples copied into wasm memory per olaf_fingerprint_match call
const INPUT_CAPACITY = 4096;

// TextDecoder is not available in every AudioWorkletGlobalScope
const decoder = typeof TextDecoder !== "undefined" ? new TextDecoder() : null;
function decode(bytes) {
	return decoder ? decoder.decode(bytes) : String.fromCharCode(...bytes);
}

// Instantiates Olaf. onMatch receives the match fields reported by the C
// matcher callback, onPrint the text Olaf writes to stdout/stderr.
// For visualisation, onSpectrum(blockIndex, magnitudes) receives the fft
// magnitudes of each audio block and onEventPoint each new event point
// ({time_index, frequency_bin, magnitude}): both on Olaf's own
// time-frequency grid, described by the returned grid.
// Returns {match, grid}: match(samples) feeds mono 16kHz samples and returns the
// audio block index; grid is {sampleRate, blockSize, stepSize, epLatencyBlocks}.
export async function instantiateOlaf(wasmBytes, { onMatch, onPrint = () => {}, onSpectrum = null, onEventPoint = null }) {
	let memory = null;

	const cString = (ptr) => {
		const bytes = new Uint8Array(memory.buffer, ptr);
		return decode(bytes.subarray(0, bytes.indexOf(0)));
	};

	// The few WASI calls the C library makes: printf output is forwarded to
	// onPrint, the others are unused by Olaf and report success.
	const wasi = {
		fd_write(fd, iovs, iovsLength, nwrittenPtr) {
			const view = new DataView(memory.buffer);
			let text = "";
			let total = 0;
			for (let i = 0; i < iovsLength; i++) {
				const ptr = view.getUint32(iovs + i * 8, true);
				const length = view.getUint32(iovs + i * 8 + 4, true);
				text += decode(new Uint8Array(memory.buffer, ptr, length));
				total += length;
			}
			view.setUint32(nwrittenPtr, total, true);
			onPrint(text);
			return 0;
		},
		environ_sizes_get(countPtr, sizePtr) {
			const view = new DataView(memory.buffer);
			view.setUint32(countPtr, 0, true);
			view.setUint32(sizePtr, 0, true);
			return 0;
		},
		environ_get: () => 0,
		fd_close: () => 0,
		fd_seek: () => 0,
		fd_fdstat_get: () => 0,
		proc_exit(code) {
			throw new Error("olaf wasm exited with code " + code);
		},
	};

	const env = {
		olaf_fp_matcher_callback(matchCount, queryStart, queryStop, pathPtr, matchIdentifier, referenceStart, referenceStop) {
			onMatch({
				match_count: matchCount,
				query_time_start: queryStart,
				query_time_stop: queryStop,
				match_name: pathPtr ? cString(pathPtr) : "",
				match_id: matchIdentifier >>> 0,
				reference_time_start: referenceStart,
				reference_time_stop: referenceStop,
			});
		},
		olaf_spectrum_callback(blockIndex, magnitudesPtr, bins) {
			// a copy: the wasm memory is reused (and can grow)
			onSpectrum?.(blockIndex, new Float32Array(memory.buffer, magnitudesPtr, bins).slice());
		},
		olaf_event_point_callback(timeIndex, frequencyBin, magnitude) {
			onEventPoint?.({ time_index: timeIndex, frequency_bin: frequencyBin, magnitude });
		},
	};

	const { instance } = await WebAssembly.instantiate(wasmBytes, { wasi_snapshot_preview1: wasi, env });
	const olaf = instance.exports;
	memory = olaf.memory;
	olaf._initialize();
	const inputPtr = olaf.malloc(INPUT_CAPACITY * 4);

	if (onSpectrum || onEventPoint) olaf.olaf_wasm_set_visualize(1);
	const gridPtr = olaf.malloc(4 * 4);
	olaf.olaf_wasm_describe(gridPtr);
	const [sampleRate, blockSize, stepSize, epLatencyBlocks] = new Int32Array(memory.buffer, gridPtr, 4);
	olaf.free(gridPtr);

	let audioBlockIndex = 0;
	return {
		grid: { sampleRate, blockSize, stepSize, epLatencyBlocks },
		match(samples) {
			for (let offset = 0; offset < samples.length; offset += INPUT_CAPACITY) {
				const chunk = samples.subarray(offset, offset + INPUT_CAPACITY);
				// a fresh view each call: the wasm memory can grow
				new Float32Array(memory.buffer, inputPtr, chunk.length).set(chunk);
				audioBlockIndex = olaf.olaf_fingerprint_match(inputPtr, chunk.length);
			}
			return audioBlockIndex;
		},
	};
}
