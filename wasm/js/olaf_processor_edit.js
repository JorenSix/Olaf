

var reported = false;
var worklet = null;
function isNumeric(n) {
  			return !isNaN(parseFloat(n)) && isFinite(n);
}

function handleStdout(text){
		const data = text.split(",");

		//an actual match
		if(!reported && data.length == 7 && isNumeric(data[0]) && parseFloat(data[0]) > 0){
    		//match found
    		const match_count = parseInt(data[0]);
    		const query_time_start = parseFloat(data[1]);
    		const query_time_stop = parseFloat(data[2]);
    		const match_name = data[3].trim();
    		const match_id = parseInt(data[4]);    		
    		const reference_time_start = parseFloat(data[5]);
    		const reference_time_stop = parseFloat(data[6]);
    
    		worklet.port.postMessage({match_count: match_count,
    			query_time_start: query_time_start,
    			query_time_stop: query_time_stop,
    			match_name: match_name,
    			match_id: match_id,
    			reference_time_start: reference_time_start,
    			reference_time_stop: reference_time_stop
    		});

    		reported = true;
    	}

    	if(data.length > 5 && isNumeric(data[0]) && parseFloat(data[0]) == 0){
    		//empty match found
    		worklet.port.postMessage({});
    	}
    	console.log(text);
	}

class OlafProcessor extends AudioWorkletProcessor {

	constructor(options){
		super(options);

		

		this.olaf = Module({'print': handleStdout});


		this.js_wrapped_olaf_fingerprint_match = this.olaf.cwrap("olaf_fingerprint_match", "number" , ["number","number"]);

		this.inputAudioBytes = 1024 * 4;
      	this.inputAudioPtr = this.olaf._malloc(this.inputAudioBytes);

      	//256 fingrprints, 8 bytes per long, 5 longs per print
      	this.fingerprintsBytes = 256 * 8 * 5;
      	this.fingerprintPtr = this.olaf._malloc(this.fingerprintsBytes);

      	reported = false;
    	worklet = this;
      	
	}

	process(inputs,outputs,parameters){
		
		reported = false;
		

		//mono first channel
		var audioInputBuffer = inputs[0][0];

		var dataHeap = new Uint8Array(this.olaf.HEAPU8.buffer, this.inputAudioPtr, this.inputAudioBytes );
    	dataHeap.set(new Uint8Array(audioInputBuffer.buffer));

    	var fingerprintHeap = new Uint8Array(this.olaf.HEAPU8.buffer, this.fingerprintPtr, this.fingerprintsBytes );
    	var fingerprintBuffer = new Uint8Array(this.fingerprintsBytes);

    	fingerprintHeap.set(new Uint8Array(this.fingerprintBuffer));

    	var audioBlockIndex = this.js_wrapped_olaf_fingerprint_match(dataHeap.byteOffset,fingerprintHeap.byteOffset);
		
		return true;
	}
}


registerProcessor('olaf-processor', OlafProcessor);
