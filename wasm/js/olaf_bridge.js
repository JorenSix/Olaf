
var audioContext = null;
var microphoneStream = null;

    
function startOrStopAudio(){
  if(audioContext == null){

  	console.log("Starting audio stream");
  	navigator.mediaDevices.getUserMedia({audio:  {sampleRate: 16000 },video: false}).then(stream => {

        microphoneStream = stream;
    		audioContext = new AudioContext();
    		var microphone = audioContext.createMediaStreamSource(stream);

        console.log(audioContext.sampleRate);

        audioContext.audioWorklet.addModule('js/olaf_processor.js').then(() => {

            // After the resolution of module loading, an AudioWorkletNode can be
            // constructed.
            let olafWorkletNode = new AudioWorkletNode(audioContext, 'olaf-processor', {
            });
            
            microphone.connect(olafWorkletNode);
            olafWorkletNode.connect(audioContext.destination);

            olafWorkletNode.port.onmessage = (event) => {
              let data = event.data;
              data['time'] = audioContext.currentTime; 
              updateMatch(data);
            };
        });

    	}).catch(err => { alert("Microphone is required." + err);});

  }else{
    console.log("Stopping audio stream");

    microphoneStream.getTracks().forEach(function(track) {
        if (track.readyState == 'live') {
            track.stop();
        }
    });

    audioContext.close();
    microphoneStream = null;
    audioContext = null;
    audioBlockIndex=0;
  }
}