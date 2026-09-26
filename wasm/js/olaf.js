// Creates the Olaf AudioWorklet node. The wasm module is fetched here, on the
// main thread (worklets cannot fetch), and handed to the processor. With
// visualize the node also posts spectra and event points (see olaf_processor.js).
export async function createOlafNode(audioContext, { visualize = false } = {}) {
	const [wasmBytes] = await Promise.all([
		fetch(new URL("olaf.wasm", import.meta.url)).then((response) => {
			if (!response.ok) throw new Error("fetching olaf.wasm failed: " + response.status + " (run `zig build web`)");
			return response.arrayBuffer();
		}),
		audioContext.audioWorklet.addModule(new URL("olaf_processor.js", import.meta.url).href),
	]);
	return new AudioWorkletNode(audioContext, "olaf-processor", {
		numberOfInputs: 1,
		numberOfOutputs: 0,
		processorOptions: { wasmBytes, visualize },
	});
}
