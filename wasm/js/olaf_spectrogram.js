// A side-scrolling spectrogram of Olaf's own fft magnitudes with its event
// points on top. The spectra and event points share Olaf's time-frequency
// grid: a column is one audio block (stepSize samples), a row one fft bin
// (sampleRate / blockSize Hz). The WebGL shader and the overlay use the same
// mapping, so an event point (timeIndex, frequencyBin) is drawn at the centre
// of the texel with that column and row.

// Number of audio blocks kept (2048 blocks of 16ms is about 33s)
const RING = 2048;

const VERTEX_SHADER = `#version 300 es
in vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }`;

// Mirrors blockToX and binToY below, in device pixels with y up
const FRAGMENT_SHADER = `#version 300 es
precision highp float;
precision highp int;
uniform highp sampler2D magnitudes;
uniform vec2 size;          // plot size in device pixels
uniform float head;         // block coordinate of the right edge
uniform float pxPerBlock;
uniform int latestBlock;
uniform int bins;
uniform float minDb;
uniform float maxDb;
out vec4 color;
void main() {
	int block = int(floor(head - (size.x - gl_FragCoord.x) / pxPerBlock));
	int bin = int(floor(gl_FragCoord.y / size.y * float(bins)));
	if (block < 0 || block > latestBlock || block <= latestBlock - ${RING}) {
		color = vec4(1.0);
		return;
	}
	float magnitude = texelFetch(magnitudes, ivec2(block % ${RING}, bin), 0).r;
	float db = 10.0 * log(max(magnitude, 1e-10)) / log(10.0);
	float level = clamp((db - minDb) / (maxDb - minDb), 0.0, 1.0);
	color = vec4(vec3(1.0 - level), 1.0);
}`;

export class OlafSpectrogram {
	// glCanvas covers the plot area, overlayCanvas the plot area plus the
	// axis margins (left, bottom), both in CSS pixels.
	constructor(glCanvas, overlayCanvas, { left = 48, bottom = 26, zoom = 2, rangeDb = 50 } = {}) {
		this.glCanvas = glCanvas;
		this.overlay = overlayCanvas;
		this.margin = { left, bottom };
		this.zoom = zoom;
		this.rangeDb = rangeDb;
		this.grid = null;

		const gl = glCanvas.getContext("webgl2", { antialias: false });
		if (!gl) throw new Error("WebGL2 is not available in this browser");
		this.gl = gl;
		this.program = this.createProgram();
		this.uniforms = {};
		for (const name of ["magnitudes", "size", "head", "pxPerBlock", "latestBlock", "bins", "minDb", "maxDb"]) {
			this.uniforms[name] = gl.getUniformLocation(this.program, name);
		}
		const buffer = gl.createBuffer();
		gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
		gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
		const position = gl.getAttribLocation(this.program, "position");
		gl.enableVertexAttribArray(position);
		gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);

		this.reset();
		new ResizeObserver(() => this.resize()).observe(overlayCanvas);
		this.resize();
		const frame = (now) => {
			this.draw(now);
			requestAnimationFrame(frame);
		};
		requestAnimationFrame(frame);
	}

	createProgram() {
		const gl = this.gl;
		const compile = (type, source) => {
			const shader = gl.createShader(type);
			gl.shaderSource(shader, source);
			gl.compileShader(shader);
			if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
			return shader;
		};
		const program = gl.createProgram();
		gl.attachShader(program, compile(gl.VERTEX_SHADER, VERTEX_SHADER));
		gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAGMENT_SHADER));
		gl.linkProgram(program);
		if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
		return program;
	}

	// Starts over for a new stream: Olaf's block indices restart at zero.
	reset() {
		this.latestBlock = -1;
		this.head = 0;
		this.maxDb = -Infinity;
		this.eventPoints = [];
		this.bins = 0;
		this.alignment = { checked: 0, mismatches: 0 };
	}

	// grid: {sampleRate, blockSize, stepSize, epLatencyBlocks} from the worklet
	setGrid(grid) {
		this.grid = grid;
		this.blockMs = 1000 * grid.stepSize / grid.sampleRate;
	}

	allocate(bins) {
		const gl = this.gl;
		this.bins = bins;
		// raw magnitudes, column (block) major: kept for the alignment check
		this.magnitudes = new Float32Array(RING * bins);
		this.blockOfColumn = new Int32Array(RING).fill(-1);
		this.texture = gl.createTexture();
		gl.bindTexture(gl.TEXTURE_2D, this.texture);
		gl.texStorage2D(gl.TEXTURE_2D, 1, gl.R32F, RING, bins);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
	}

	// A {type: "spectrum"} message from the worklet
	add({ firstBlock, count, bins, magnitudes, eventPoints }) {
		const gl = this.gl;
		if (count > 0 && bins !== this.bins) this.allocate(bins);
		for (let i = 0; i < count; i++) {
			const block = firstBlock + i;
			const column = block % RING;
			const spectrum = magnitudes.subarray(i * bins, (i + 1) * bins);
			this.magnitudes.set(spectrum, column * bins);
			this.blockOfColumn[column] = block;
			gl.bindTexture(gl.TEXTURE_2D, this.texture);
			gl.texSubImage2D(gl.TEXTURE_2D, 0, column, 0, 1, bins, gl.RED, gl.FLOAT, spectrum);

			// dynamic range: follow the loudest column, slowly decaying
			let max = 0;
			for (let j = 0; j < bins; j++) if (spectrum[j] > max) max = spectrum[j];
			const db = 10 * Math.log10(Math.max(max, 1e-10));
			this.maxDb = Math.max(db, this.maxDb - 0.02);
			this.latestBlock = block;
		}
		for (const ep of eventPoints) {
			this.checkAlignment(ep);
			this.eventPoints.push(ep);
		}
		const oldest = this.latestBlock - RING;
		while (this.eventPoints.length > 0 && this.eventPoints[0].time_index <= oldest) this.eventPoints.shift();
	}

	// An event point is a peak of the spectrum: its magnitude must be the
	// stored magnitude at its block and bin.
	checkAlignment(ep) {
		const column = ep.time_index % RING;
		this.alignment.checked++;
		if (ep.time_index < 0 || this.blockOfColumn[column] !== ep.time_index ||
			this.magnitudes[column * this.bins + ep.frequency_bin] !== Math.fround(ep.magnitude)) {
			this.alignment.mismatches++;
		}
	}

	resize() {
		const dpr = window.devicePixelRatio || 1;
		for (const canvas of [this.glCanvas, this.overlay]) {
			const rect = canvas.getBoundingClientRect();
			canvas.width = Math.round(rect.width * dpr);
			canvas.height = Math.round(rect.height * dpr);
		}
		this.dpr = dpr;
	}

	// Plot coordinates in device pixels, y down, origin top left of the plot.
	// A block coordinate b.x lies in column b; a bin coordinate k.y in row k.
	blockToX(blockCoordinate) {
		return this.glCanvas.width - (this.head - blockCoordinate) * this.zoom * this.dpr;
	}
	binToY(binCoordinate) {
		return this.glCanvas.height - binCoordinate * this.glCanvas.height / this.bins;
	}

	// Scroll at the audio rate, never past the newest block
	advanceHead(now) {
		const target = this.latestBlock + 1;
		const elapsed = this.lastFrame === undefined ? 0 : now - this.lastFrame;
		this.lastFrame = now;
		if (!this.blockMs || target - this.head > 8 || this.head > target) {
			this.head = target;
		} else {
			this.head = Math.min(target, this.head + elapsed / this.blockMs);
		}
	}

	draw(now) {
		this.advanceHead(now);
		const gl = this.gl;
		const width = this.glCanvas.width;
		const height = this.glCanvas.height;
		gl.viewport(0, 0, width, height);
		if (this.bins === 0) {
			gl.clearColor(1, 1, 1, 1);
			gl.clear(gl.COLOR_BUFFER_BIT);
		} else {
			gl.useProgram(this.program);
			gl.activeTexture(gl.TEXTURE0);
			gl.bindTexture(gl.TEXTURE_2D, this.texture);
			const u = this.uniforms;
			gl.uniform1i(u.magnitudes, 0);
			gl.uniform2f(u.size, width, height);
			gl.uniform1f(u.head, this.head);
			gl.uniform1f(u.pxPerBlock, this.zoom * this.dpr);
			gl.uniform1i(u.latestBlock, this.latestBlock);
			gl.uniform1i(u.bins, this.bins);
			gl.uniform1f(u.maxDb, this.maxDb);
			gl.uniform1f(u.minDb, this.maxDb - this.rangeDb);
			gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
		}
		this.drawOverlay();
	}

	drawOverlay() {
		const ctx = this.overlay.getContext("2d");
		const dpr = this.dpr;
		const left = this.margin.left * dpr;
		const width = this.glCanvas.width;
		const height = this.glCanvas.height;
		ctx.clearRect(0, 0, this.overlay.width, this.overlay.height);
		if (!this.grid || this.bins === 0) return;

		ctx.save();
		ctx.translate(left, 0);

		// event points at the centre of their texel
		ctx.save();
		ctx.beginPath();
		ctx.rect(0, 0, width, height);
		ctx.clip();
		ctx.fillStyle = "rgba(230, 0, 0, 0.9)";
		const radius = Math.max(2.5, Math.min(5, this.zoom * 1.5)) * dpr;
		for (const ep of this.eventPoints) {
			const x = this.blockToX(ep.time_index + 0.5);
			if (x < -radius) continue;
			ctx.beginPath();
			ctx.arc(x, this.binToY(ep.frequency_bin + 0.5), radius, 0, 2 * Math.PI);
			ctx.fill();
		}
		ctx.restore();

		// axes: block b is at b * stepSize / sampleRate seconds (Olaf's time
		// convention), bin k at k * sampleRate / blockSize Hz
		const { sampleRate, blockSize, stepSize } = this.grid;
		const blocksPerSecond = sampleRate / stepSize;
		const binsPerHz = blockSize / sampleRate;
		ctx.fillStyle = ctx.strokeStyle = "#6b7280";
		ctx.lineWidth = dpr;
		ctx.font = `${11 * dpr}px ui-monospace, Menlo, monospace`;

		ctx.textAlign = "right";
		ctx.textBaseline = "middle";
		for (let hz = 0; hz <= sampleRate / 2; hz += 1000) {
			const y = Math.min(height - dpr / 2, Math.max(dpr / 2, this.binToY(hz * binsPerHz + 0.5)));
			ctx.beginPath();
			ctx.moveTo(-5 * dpr, y);
			ctx.lineTo(0, y);
			ctx.stroke();
			// keep the labels at the plot edges inside the canvas
			ctx.textBaseline = y < 6 * dpr ? "top" : y > height - 6 * dpr ? "bottom" : "middle";
			ctx.fillText(hz === 0 ? "0" : hz / 1000 + "k", -7 * dpr, y);
		}
		ctx.save();
		ctx.translate(-36 * dpr, height / 2);
		ctx.rotate(-Math.PI / 2);
		ctx.textAlign = "center";
		ctx.fillText("Hz", 0, 0);
		ctx.restore();

		ctx.textAlign = "center";
		ctx.textBaseline = "top";
		const firstSecond = Math.max(0, Math.ceil((this.head - width / (this.zoom * dpr)) / blocksPerSecond));
		for (let s = firstSecond; s * blocksPerSecond <= this.head; s++) {
			const x = this.blockToX(s * blocksPerSecond + 0.5);
			if (x < 0 || x > width - 10 * dpr) continue;
			ctx.beginPath();
			ctx.moveTo(x, height);
			ctx.lineTo(x, height + 5 * dpr);
			ctx.stroke();
			ctx.fillText(s + "s", x, height + 7 * dpr);
		}
		ctx.restore();
	}
}
