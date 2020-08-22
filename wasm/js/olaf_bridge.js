
var audioContext = null;

var js_wrapped_olaf_fft_frequency_estimate = Module.cwrap("olaf_fft_frequency_estimate", "number", ["number","number"]);
var js_wrapped_olaf_fingerprint_match = Module.cwrap("olaf_fingerprint_match", "number" , ["number","number"]);

var fingerprintData = [];
var fingerprintsToPlot = [];

var frequencyDataArray = [];
var audioBlockIndex = 0;

function processAudioWithOlaf(audioProcessingEvent) {
        
    var inputBuffer = audioProcessingEvent.inputBuffer;

    //Only handle a single channel of audio
    var audioInputBuffer = inputBuffer.getChannelData(0);

    // Get data byte size, allocate memory on Emscripten heap, and get pointer
    var inputAudioBytes = audioInputBuffer.length * audioInputBuffer.BYTES_PER_ELEMENT;
    var inputAudioPtr = Module._malloc(inputAudioBytes);

    //256 fingrprints, 8 bytes per long, 5 longs per print
    var fingerprintsBytes = 256 * 8 * 5;
    var fingerprintPtr = Module._malloc(fingerprintsBytes);
    var fingerprintBuffer = new Uint8Array(fingerprintsBytes);

    // Copy data to Emscripten heap (directly accessed from Module.HEAPU8)
    var dataHeap = new Uint8Array(Module.HEAPU8.buffer, inputAudioPtr, inputAudioBytes );
    dataHeap.set(new Uint8Array(audioInputBuffer.buffer));

    //console.log(audioInputBuffer.playbackTime)

    var fingerprintHeap = new Uint8Array(Module.HEAPU8.buffer, fingerprintPtr, fingerprintsBytes );
    fingerprintHeap.set(new Uint8Array(fingerprintBuffer));

    audioBlockIndex = js_wrapped_olaf_fingerprint_match(dataHeap.byteOffset,fingerprintHeap.byteOffset);
    //frequency = js_wrapped_olaf_fft_frequency_estimate(dataHeap.byteOffset,256);

    //Retrieve the frequency domain data
    var frequencyData = new Float32Array(Module.HEAPF32.buffer, inputAudioPtr, audioInputBuffer.length);

    frequencyDataArray.push([frequencyData,audioBlockIndex,false]);

    //Retriev the fingerprint data
    fingerprintData = new Uint32Array(Module.HEAPU32.buffer, fingerprintPtr, 256*6);

    var t1 = fingerprintData[0]
    for( var i = 0 ; t1 != 0 && i < 256 * 6 ; i+=6){
      var f1 = fingerprintData[i+1];
      var t2 = fingerprintData[i+2];
      var f2 = fingerprintData[i+3];
      var fhash = fingerprintData[i+4];
      var inDb = fingerprintData[i+5];

      fingerprintsToPlot.push([t1,f1,t2,f2,fhash,inDb]);

      t1 = fingerprintData[i+6];
    }

    Module._free(dataHeap.byteOffset);
    Module._free(fingerprintHeap.byteOffset);

    audioBlockIndex += 1

    drawFrequencyData()
    drawFingerprints()
}

    
function startOrStopAudio(){
  if(audioContext == null){

  	console.log("Starting audio stream")
  	navigator.mediaDevices.getUserMedia({audio: true,video: false}).then(stream => {

    		audioContext = new AudioContext({sampleRate: 8000});
    		microphone = audioContext.createMediaStreamSource(stream);

    		var olafScriptProcessorNode = audioContext.createScriptProcessor(256, 1, 1);
    		olafScriptProcessorNode.onaudioprocess = processAudioWithOlaf;

    		microphone.connect(olafScriptProcessorNode);
    		olafScriptProcessorNode.connect(audioContext.destination);

    	}).catch(err => { alert("Microphone is required." + err);});

  }else{
    audioContext.close();
    audioContext = null;
    audioBlockIndex=0;
  }
}