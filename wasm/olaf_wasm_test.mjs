// Runs the browser module (olaf.wasm) in node, through the same loader as the
// AudioWorklet: a query of the reference compiled into the module must match,
// deterministic noise must not. Event points must line up with the spectrum:
// each event point's magnitude is the spectrum value at its time and
// frequency bin. Requires ffmpeg to decode the query.
//
//   node wasm/olaf_wasm_test.mjs [olaf.wasm] [query audio]
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { instantiateOlaf } from "./js/olaf_wasm.js";

const REFERENCE_ID = 1051039; // the reference in src/olaf_fp_ref_mem.h
const wasmPath = process.argv[2] ?? fileURLToPath(new URL("js/olaf.wasm", import.meta.url));
const queryPath = process.argv[3] ?? fileURLToPath(new URL("../dataset/queries/1051039_34s-54s.mp3", import.meta.url));
const wasmBytes = readFileSync(wasmPath);

// Feeds samples in 128-sample blocks, like an AudioWorklet, and returns the
// matches and the event points that do not line up with the spectrum.
async function run(samples) {
	const results = [];
	const spectra = [];
	const misaligned = [];
	let eventPoints = 0;
	let currentBlock = 0;
	const olaf = await instantiateOlaf(wasmBytes, {
		onMatch: (match) => results.push(match),
		onSpectrum: (blockIndex, magnitudes) => {
			currentBlock = blockIndex;
			spectra[blockIndex] = magnitudes;
		},
		onEventPoint: (ep) => {
			eventPoints++;
			const spectrum = spectra[ep.time_index];
			if (ep.time_index > currentBlock || !spectrum || spectrum[ep.frequency_bin] !== Math.fround(ep.magnitude)) {
				misaligned.push(ep);
			}
		},
	});
	for (let offset = 0; offset + 128 <= samples.length; offset += 128) {
		olaf.match(samples.subarray(offset, offset + 128));
	}
	return { matches: results.filter((match) => match.query_time_start > 0), eventPoints, misaligned };
}

const raw = execFileSync("ffmpeg", ["-loglevel", "error", "-i", queryPath, "-ac", "1", "-ar", "16000", "-f", "f32le", "-"], { maxBuffer: 1 << 28 });
const query = new Float32Array(raw.buffer, raw.byteOffset, raw.byteLength / 4);

const noise = new Float32Array(16000 * 10);
let seed = 42;
for (let i = 0; i < noise.length; i++) {
	seed = (seed * 1664525 + 1013904223) >>> 0;
	noise[i] = (seed / 0xFFFFFFFF) * 0.5 - 0.25;
}

const queryRun = await run(query);
const noiseRun = await run(noise);
const queryMatches = queryRun.matches;
const noiseMatches = noiseRun.matches;
const hits = queryMatches.filter((match) => match.match_id === REFERENCE_ID);
console.log(`query: ${hits.length}/${queryMatches.length} matches for ${REFERENCE_ID}, noise: ${noiseMatches.length} matches, ` +
	`event points: ${queryRun.eventPoints} (${queryRun.misaligned.length} misaligned)`);
if (hits.length === 0 || hits.length !== queryMatches.length || noiseMatches.length !== 0 ||
	queryRun.eventPoints === 0 || queryRun.misaligned.length !== 0 || noiseRun.misaligned.length !== 0) {
	console.error("FAIL", JSON.stringify({ queryMatches, noiseMatches, misaligned: queryRun.misaligned.slice(0, 10) }));
	process.exit(1);
}
