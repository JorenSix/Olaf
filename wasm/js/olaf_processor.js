// The Olaf AudioWorklet: resamples the input to 16kHz and matches it against
// the fingerprints compiled into olaf.wasm. Create it with createOlafNode (olaf.js).
// With processorOptions.visualize it also posts the spectra and event points
// ({type: "spectrum"}) on Olaf's time-frequency grid ({type: "grid"}).
import { create } from "./libsamplerate.worklet.js";
import { instantiateOlaf } from "./olaf_wasm.js";

//The sample rate expected by Olaf
const targetSampleRate = 16000;

class OlafProcessor extends AudioWorkletProcessor {

	constructor(options) {
		super(options);

		const status = (message) => this.port.postMessage({ type: "status", message });
		//report through the port: worklet console output is not always visible
		const error = (message) => this.port.postMessage({ type: "status", error: message });

		//only resample when the audio context is not already at the target sample rate
		if (sampleRate === targetSampleRate) {
			this.resample = (samples) => samples;
		} else {
			create(1, sampleRate, targetSampleRate, {})
				.then((src) => {
					this.resample = (samples) => src.full(samples);
					status("resampler ready (" + sampleRate + " -> " + targetSampleRate + "Hz)");
				})
				.catch((err) => error("resampler failed: " + err));
		}

		const visualize = options.processorOptions.visualize === true;
		this.spectra = [];
		this.eventPoints = [];

		instantiateOlaf(options.processorOptions.wasmBytes, {
			onMatch: (match) => this.port.postMessage(match),
			onPrint: (text) => text.trim() && status(text.trim()),
			onSpectrum: visualize ? (blockIndex, magnitudes) => this.spectra.push({ blockIndex, magnitudes }) : null,
			onEventPoint: visualize ? (ep) => this.eventPoints.push(ep) : null,
		})
			.then((olaf) => {
				this.olaf = olaf;
				if (visualize) this.port.postMessage({ type: "grid", ...olaf.grid });
				status("olaf wasm ready");
			})
			.catch((err) => error("olaf wasm failed: " + err));

		this.processCalls = 0;
	}

	//Processes mono audio
	process(inputs) {
		//wait for the modules to initialize, ignore when not ready
		if (this.olaf == null || this.resample == null) {
			return true;
		}

		//mono first channel; inputs can be empty when the source has
		//ended or the microphone stream stopped
		const input = inputs.length > 0 && inputs[0].length > 0 ? inputs[0][0] : null;
		if (input == null || input.length === 0) {
			return true;
		}

		if (this.processCalls === 0) {
			this.port.postMessage({ type: "status", message: "processing audio" });
		}
		this.processCalls++;

		try {
			const audioBlockIndex = this.olaf.match(this.resample(input));
			//progress report roughly every 2.7s (128 samples per call at 48kHz)
			if (this.processCalls % 1000 === 0) {
				this.port.postMessage({ type: "status", message: "audio block index " + audioBlockIndex + " after " + this.processCalls + " calls" });
			}
		} catch (err) {
			if (!this.reportedError) {
				this.reportedError = true;
				this.port.postMessage({ type: "status", error: "wasm match call failed: " + err + (err && err.stack ? " | " + err.stack : "") });
			}
		}

		this.postSpectra();
		return true;
	}

	//Posts the spectra and event points of this render quantum in one message
	postSpectra() {
		if (this.spectra.length === 0 && this.eventPoints.length === 0) {
			return;
		}
		const bins = this.spectra.length > 0 ? this.spectra[0].magnitudes.length : 0;
		const magnitudes = new Float32Array(this.spectra.length * bins);
		this.spectra.forEach((spectrum, i) => magnitudes.set(spectrum.magnitudes, i * bins));
		this.port.postMessage({
			type: "spectrum",
			firstBlock: this.spectra.length > 0 ? this.spectra[0].blockIndex : -1,
			count: this.spectra.length,
			bins,
			magnitudes,
			eventPoints: this.eventPoints,
		}, [magnitudes.buffer]);
		this.spectra = [];
		this.eventPoints = [];
	}
}

registerProcessor("olaf-processor", OlafProcessor);
