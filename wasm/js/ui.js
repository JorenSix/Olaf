// create an new instance of a pixi stage

let app = new PIXI.Application({width: window.innerWidth, height: window.innerHeight});

app.renderer.view.style.position = "absolute";
app.renderer.view.style.display = "block";
app.renderer.resize(window.innerWidth, window.innerHeight);
app.renderer.backgroundColor = 0xFFFFFF;
app.stage.interactive = true;

document.body.appendChild(app.view);

var width = window.innerWidth;
var height = window.innerHeight;

var leftOffset = 50;
var bottomOffset = 50;

var speed = 8;

let text = new PIXI.Text('Click or Tap to start your microphone',{fontFamily : 'Arial', fontSize: 28, fill : 0x000000, align : 'center'});
text.x = width/2+leftOffset;
text.y = height/2-bottomOffset;
text.anchor.set(0.5, 0.5);
app.stage.addChild(text)

function drawAxis(){
	var graphics = new PIXI.Graphics();
	graphics.lineStyle(2, 0x000000, 1);
	graphics.drawRect(leftOffset, 0, 2, height-bottomOffset);
	graphics.drawRect(leftOffset, height-bottomOffset, width-leftOffset , 2);
	app.stage.addChild(graphics);
}

function audioBlockIndexToX(t){
	//var timeWidthPixels = width - leftOffset;
	//var widthInBlocks = timeWidthPixels/8;
	currentTime = audioContext.currentTime;
    var delta = (audioBlockIndex - t);
    console.log(delta)
    return width - delta*4;
}

function fftBinStartStopY(fftBinIndex){
	var freqHeightPixels = height - bottomOffset;
	
	var startPercent = (fftBinStartMidiKey(fftBinIndex) - midiKeyStart) / midiKeyRange;
	var startY = (1 - startPercent) * freqHeightPixels;

	var stopPercent = (fftBinStopMidiKey(fftBinIndex) - midiKeyStart) / midiKeyRange;
	var stopY = (1  - stopPercent) * freqHeightPixels;

	return [startY,stopY];
}

function fftBinStartMidiKey(fftBinIndex){
	startInHz = sampleRate/fftSize * fftBinIndex;
	return hzToMidiKey(startInHz);
}

function fftBinStopMidiKey(fftBinIndex){
	return fftBinStartMidiKey(fftBinIndex+1)
}

function hzToFFTBin(startFrequency){
	return Math.round(startFrequency * fftSize / sampleRate);
}

function midiKeyToHz(midiKey){
	return 440.0 * Math.pow(2,(midiKey-69)/12)
}

function hzToMidiKey(frequencyInHz){
	return 69 + 12 * logBase(frequencyInHz/440.0,2);
}

function logBase(val, base) {
	return Math.log(val) / Math.log(base);
}

function getGrayColor(value) {
	return  value + value * 256 + value * 256 * 256;
}
var maxMag = 0
function drawFrequencyData(){
	//var fftFrames = []

	//frequencyDataArray
	if(!frequencyDataArray)
	return 

	var speed = 4;

	for(var i = 0 ; i < frequencyDataArray.length ; i++){
		drawn = frequencyDataArray[i][2]
		if(!drawn){
		
			frequencyDataArray[i][2] = true
			var frequencyData = frequencyDataArray[i][0]
			frequencyDataArray.pop()

			var fftBinIndexStart = hzToFFTBin(midiKeyToHz(midiKeyStart))
			var fftBinIndexStop = hzToFFTBin(midiKeyToHz(midiKeyStop))

			//console.log("bin index stop", fftBinIndexStop)

			var fftFrame = new PIXI.Container();
			for(var fftBinIndex = fftBinIndexStart - 1  ; fftBinIndex < fftBinIndexStop ; fftBinIndex++){

				var value = frequencyData[fftBinIndex];
				if(value){
        			value = Math.log(value+1)/Math.log(2);
        			maxMag = Math.max(maxMag,value);
      			}

      			maxMag = maxMag * 0.999;
      			
      			var color  = colorScale(value/maxMag).num();

      			var startStopY = fftBinStartStopY(fftBinIndex);

				let rectangle = new PIXI.Graphics();

				rectangle.lineStyle(1, color, 1);
				rectangle.beginFill(color);

				rectangle.drawRect(0, startStopY[0], speed, startStopY[1] - startStopY[0]);
				rectangle.endFill();
				fftFrame.addChild(rectangle);
			}

			fftFrame.cacheAsBitmap = true;
			fftFrame.position.x = width;
			fftFrame.position.y = 0;
			app.stage.addChild(fftFrame);

			// rotate the container!
			// use delta to create frame-independent transform
			for(var i = 1 ; i < app.stage.children.length - 1; i++){
				var child = app.stage.getChildAt(i)

				child.x = child.x - speed;
		    	if(child.x < leftOffset ){
		    		app.stage.removeChild(child);
		    		child.destroy();
		    		child = null;
		    	}
			}
		}
	}

}


function drawFingerprints(){

  //tempCanvas.width = width;
  //tempCanvas.height = height;
  //console.log(this.$.canvas.height, this.tempCanvas.height);
  //var tempCtx = tempCanvas.getContext('2d');
 // tempCtx.drawImage(printsCanvas, 0, 0, width, height);
  if(fingerprintsToPlot){

  	var count = 0;

    for (var i = 0; i < fingerprintsToPlot.length; i++){

      var data = fingerprintsToPlot[i];
      var t1 = data[0];
      var f1 = data[1];
      var t2 = data[2];
      var f2 = data[3];
      var fhash = data[4];
      var inDb = data[5];

      fingerprintsToPlot.pop();

      if(t1 == 0)
        break;

      

      var pointContainer = new PIXI.Container();

      let point = new PIXI.Graphics();

	  point.lineStyle(1, 0xFF0000, 1);
	  point.beginFill(0xFF0000);
	  point.drawCircle(0, fftBinStartStopY(f1)[0], 3);
	  point.endFill();

	  pointContainer.addChild(point);

	  pointContainer.position.x = audioBlockIndexToX(t1);
	  pointContainer.position.y = 0;
	  pointContainer.cacheAsBitmap = true;

	  app.stage.addChild(pointContainer);


	  point.lineStyle(1, 0xFF0000, 1);
	  point.beginFill(0xFF0000);
	  point.drawCircle(0, fftBinStartStopY(f2)[0], 3);
	  point.endFill();

	  pointContainer.addChild(point);

	  pointContainer.position.x = audioBlockIndexToX(t2);
	  pointContainer.position.y = 0;
	  pointContainer.cacheAsBitmap = true;

	  app.stage.addChild(pointContainer);

	  console.log(audioBlockIndexToX(t1),fftBinStartStopY(f1)[0])

	  count = count + 1;
    }

    if(count > 0){
     
    }
  }
 }


drawAxis();
drawFrequencyData();

function onClick(){
	console.log("click")

	app.stage.removeChild( app.stage.getChildAt(0))
	startOrStopAudio();
}
// Combines both mouse click + touch tap
app.stage.on('pointertap', onClick);

app.ticker.add((delta) => {
	//drawFrequencyData();
});

window.addEventListener('resize', function(event){
	width = window.innerWidth;
	height = window.innerHeight;
	
	//clear stage
	while(app.stage.children.length > 0){   
		var child = app.stage.getChildAt(0) 
		app.stage.removeChild(child)
	}

	app.renderer.resize(window.innerWidth, window.innerHeight);

	drawAxis();
	drawFrequencyData();
});
