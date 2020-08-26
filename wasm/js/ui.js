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

var speed = 4;

var maxMag = 0;

var drawnPoints = new Set();

function drawText(){
	let text = new PIXI.Text('Click to start\nmicrophone',{fontFamily : 'Arial', fontSize: 28, fill : 0x000000, align : 'center'});
	text.x = width/2;
	text.y = height/2;
	text.anchor.set(0.5, 0.5);
	app.stage.addChild(text);
}

function audioBlockIndexToX(t){
    var delta = (audioBlockIndex - t - 1);
    return width - delta * speed;
}

function fftBinStartStopY(fftBinIndex){
	var freqHeightPixels = height;
	
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

function shiftContainer(){

	// rotate the container!
	// use delta to create frame-independent transform
	for(var i = 1 ; i < app.stage.children.length - 1; i++){
		var child = app.stage.getChildAt(i)

		child.x = child.x - speed;
		if(child.x < 0 ){
			app.stage.removeChild(child);
			child.destroy();
			child = null;
		}
	}
}

function drawFrequencyData(){
	//var fftFrames = []

	//frequencyDataArray
	if(!frequencyDataArray) return;

	for(var i = 0 ; i < frequencyDataArray.length ; i++){
		drawn = frequencyDataArray[i][2]
		if(!drawn){
			frequencyDataArray[i][2] = true
			var frequencyData = frequencyDataArray[i][0]
			frequencyDataArray.pop()

			var fftBinIndexStart = hzToFFTBin(midiKeyToHz(midiKeyStart))
			var fftBinIndexStop = hzToFFTBin(midiKeyToHz(midiKeyStop))

			var fftFrame = new PIXI.Container();
			for(var fftBinIndex = fftBinIndexStart  ; fftBinIndex < fftBinIndexStop ; fftBinIndex++){

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

			shiftContainer();
		}
	}
	drawFingerprints();
}


function drawFingerprints(){

  //tempCanvas.width = width;
  //tempCanvas.height = height;
  //console.log(this.$.canvas.height, this.tempCanvas.height);
  //var tempCtx = tempCanvas.getContext('2d');
 // tempCtx.drawImage(printsCanvas, 0, 0, width, height);
  if(fingerprintsToPlot){

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

      let point = new PIXI.Graphics();

      var color = 0xFF00000;
      if(inDb > 6){
      	color = 0x00FF00;
      }


      var t1f1key = t1 + "_" + f1;

      if(!drawnPoints.has(t1f1key)){
      	var pointContainer = new PIXI.Container();
		  point.lineStyle(1, color, 1);
		  point.beginFill(color);
		  point.drawCircle(0, fftBinStartStopY(f1)[0], 3);
		  point.endFill();
		  pointContainer.addChild(point);
		  pointContainer.position.x = audioBlockIndexToX(t1);
		  pointContainer.position.y = 0;
		  pointContainer.cacheAsBitmap = true;
		  app.stage.addChild(pointContainer);

		  drawnPoints.add(t1f1key);
      }
      

      var t2f2key = t2 + "_" + f2;
      if(!drawnPoints.has(t2f2key)){
		  pointContainer = new PIXI.Container();
		  point.lineStyle(1, color, 1);
		  point.beginFill(color);
		  point.drawCircle(0, fftBinStartStopY(f2)[0], 3);
		  point.endFill();
		  pointContainer.addChild(point);
		  pointContainer.position.x = audioBlockIndexToX(t2);
		  pointContainer.position.y = 0;
		  pointContainer.cacheAsBitmap = true;
		  app.stage.addChild(pointContainer);

		  drawnPoints.add(t2f2key);
	  }
    }
  }
 }



function onClick(){
	console.log("click")

	app.stage.removeChild(app.stage.getChildAt(0))

	startOrStopAudio();
}

drawText();

// Combines both mouse click + touch tap
app.stage.on('pointertap', onClick);

window.addEventListener('resize', function(event){
	width = window.innerWidth;
	height = window.innerHeight;
	
	//clear stage
	while(app.stage.children.length > 0){   
		var child = app.stage.getChildAt(0) 
		app.stage.removeChild(child)
	}

	app.renderer.resize(window.innerWidth, window.innerHeight);

	if(audioContext){
		drawFrequencyData();
	}else{
		drawText();
	}
});
