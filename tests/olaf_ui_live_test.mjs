// Tests execute the actual inline script, not a copy of its timing logic.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import {execFileSync} from 'node:child_process';
const html=readFileSync(new URL('../cli/ui/olaf_ui_live.html',import.meta.url),'utf8');
const context={};runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],context);
const {Ring,wav,alignment,expired,eligible,Monitor,workletSource}=context.OlafLive;
const ring=new Ring(10);ring.push(100,new Float32Array(100).fill(1));ring.push(200,new Float32Array(100).fill(2));
let snap=ring.snapshot();assert.equal(snap.startFrame,150);assert.equal(snap.endFrame,300);assert.equal(snap.samples.length,150);assert.equal(snap.samples[49],1);assert.equal(snap.samples[50],2);
assert.equal(ring.push(400,new Float32Array(20)),false);assert.equal(ring.snapshot().startFrame,400);
const encoded=wav(new Float32Array([-1,0,1]),48000),view=new DataView(encoded);
assert.equal(view.getUint32(24,true),48000);assert.equal(view.getInt16(44,true),-32768);assert.equal(view.getInt16(48,true),32767);
const timing=alignment(18.25,{startFrame:240000,endFrame:720000,sampleRate:48000},{reference_start:72,query_start:2,clip_start:75});
assert.equal(timing.at,18.3);assert.ok(Math.abs(timing.reference-83.34)<1e-9);assert.ok(Math.abs(timing.offset-8.34)<1e-9);
assert.equal(expired(30,15),true);assert.equal(expired(29.999,15),false);assert.equal(eligible({recent:false},true),false);
// Delayed worklet messages preserve sample-frame timestamps, including gaps.
let Capture;const sent=[];const worklet={currentFrame:48000,AudioWorkletProcessor:class{constructor(){this.port={postMessage:m=>sent.push(m)};}},registerProcessor:(_,c)=>Capture=c};
runInNewContext(workletSource,worklet);const capture=new Capture();for(let i=0;i<16;i++){worklet.currentFrame=48000+i*128;capture.process([[new Float32Array(128).fill(0.25)]]);}
assert.equal(sent[0].frame,48000);assert.equal(sent[0].samples.length,2048);
worklet.currentFrame=99999;capture.process([[new Float32Array(128)]]);assert.equal(capture.start,99999);capture.port.onmessage();assert.equal(capture.used,0);assert.equal(capture.next,null);
// Single-flight requests and snapshot-based cadence; discontinuities invalidate state.
const fake={active:true,ctx:{state:'running'},ring:new Ring(10),nextFrame:0,busy:false,ui:{capture:{}},query(){this.calls=(this.calls||0)+1;this.busy=true;},invalidate(){this.ring.clear();this.busy=false;this.resets=(this.resets||0)+1;}};
Monitor.prototype.captured.call(fake,{frame:0,samples:new Float32Array(50)});Monitor.prototype.captured.call(fake,{frame:50,samples:new Float32Array(50)});assert.equal(fake.calls,1);
Monitor.prototype.captured.call(fake,{frame:200,samples:new Float32Array(10)});assert.equal(fake.resets,1);fake.minFrame=300;Monitor.prototype.captured.call(fake,{frame:250,samples:new Float32Array(20)});assert.equal(fake.ring.end,210);
// Exercise real playback lifecycle with an audio-clock scheduling spy.
function player(){
  const scheduled=[];
  const p=Object.assign(Object.create(Monitor.prototype),{
    ctx:{currentTime:12,createBufferSource(){const source={connect(){},disconnect(){},stop(t){this.stopAt=t;},start(at,offset){this.at=at;this.offset=offset;}};scheduled.push(source);return source;},
      createGain:()=>({connect(){},disconnect(){},gain:{value:1,events:[],setValueAtTime(...x){this.events.push(['set',...x]);},linearRampToValueAtTime(...x){this.events.push(['ramp',...x]);},cancelAndHoldAtTime(t){this.events=this.events.filter(e=>e[2]<t);}}})},
    master:{},current:null,queued:null,sources:new Set(),trace:[],ui:{current:{}},highlight(){}});
  return {p,scheduled};
}
const match={path:'song.mp3',match_identifier:1,match_count:9,reference_start:70,query_start:0,clip_start:75};
const snapshot={requestId:1,startFrame:0,endFrame:105,sampleRate:10};
const delayed=alignment(12,snapshot,match);
assert.ok(Math.abs(delayed.reference-82.09)<1e-9); // 80.5 at capture end + 1.5 response delay + 0.05 lead + 0.04 device latency.
let {p,scheduled}=player();
p.play({duration:30},match,delayed,snapshot);
const original=p.current;
assert.equal(original.source.stopAt,25.6);
for(const now of [14.5,17,19.5]){
  p.ctx.currentTime=now;
  const snap={...snapshot,endFrame:now*10};
  p.play({duration:30},match,alignment(now,snap,match),snap);
  assert.equal(p.current,original);
}
assert.equal(scheduled.length,1);assert.equal(original.source.stopAt,34.6);
// A missing query does not alter the scheduled deadline, including background tabs.
assert.equal(expired(34.499,19.5),false);assert.equal(expired(34.5,19.5),true);
assert.ok(original.gain.gain.events.some(e=>e[0]==='set'&&e[2]===34.5));
// Replenish the finite clip without resetting the timeline; cancel superseded handoffs.
p.ctx.currentTime=22;
const newer={...match,clip_start:87};
p.play({duration:30},newer,alignment(22,snapshot,newer),{...snapshot,endFrame:220});
assert.equal(p.current,original);assert.ok(p.queued);
assert.ok(original.gain.gain.events.some(e=>e[0]==='set'&&e[1]===1&&e[2]===p.queued.at));
const queued=p.queued;assert.ok(Math.abs(queued.reference-(original.reference+queued.at-original.at))<1e-9);
// Handoffs inherit the compensated timeline; device latency is not added twice.
assert.ok(Math.abs(queued.reference-(70+queued.at+0.04))<1e-9);
assert.ok(Math.abs(queued.offset-(queued.reference-newer.clip_start))<1e-9);
p.ctx.currentTime=24.5;
p.play({duration:30},newer,alignment(24.5,snapshot,newer),{...snapshot,endFrame:245});
assert.notEqual(p.queued,queued);assert.equal(queued.source.stopAt,undefined);
p.ctx.currentTime=p.queued.at+0.1;original.source.onended();assert.notEqual(p.current,original);assert.equal(p.queued,null);
// Significant timing changes and different references switch immediately.
p.ctx.currentTime=36;
const corrected={...newer,reference_start:72};
p.play({duration:30},corrected,alignment(36,snapshot,corrected),{...snapshot,endFrame:360});
const resynced=p.current;assert.ok(Math.abs(resynced.reference-108.09)<1e-9);
const other={...corrected,match_identifier:2};
p.play({duration:30},other,alignment(36,snapshot,other),{...snapshot,endFrame:360});
assert.notEqual(p.current,resynced);assert.equal(p.current.match.match_identifier,2);
p.fade();assert.equal(p.current,null);assert.equal(p.queued,null);
// Response/decode latency changes offsets; a superseded decode cannot play.
const requests=[];
context.XMLHttpRequest=class { constructor(){requests.push(this);}open(){}setRequestHeader(){}send(){}abort(){this.onabort?.();} };
context.atob=s=>Buffer.from(s,'base64').toString('binary');
function client(){
  const ring=new Ring(10);ring.push(0,new Float32Array(50));let resolve;
  const c={ring,session:1,sequence:0,active:true,busy:false,established:false,ctx:{currentTime:6,decodeAudioData:()=>new Promise(r=>resolve=r)},
    status(){},error(s){this.failure=s;},renderMatches(){},play(buffer,match,timing){this.played=timing;},get resolve(){return resolve;}};
  Monitor.prototype.query.call(c);const xhr=requests.at(-1);xhr.status=200;xhr.response={session_id:'1',request_id:'1',data:{matches:[{recent:true,audio:'AAAA',reference_start:15,query_start:0,clip_start:15}],selected_index:0}};
  return {c,xhr};
}
let pending=client();let completion=pending.xhr.onload();pending.c.ctx.currentTime=8;pending.c.resolve({duration:30});await completion;
assert.ok(Math.abs(pending.c.played.offset-8.09)<1e-9);assert.equal(pending.c.busy,false);
pending=client();completion=pending.xhr.onload();pending.c.session++;pending.c.resolve({duration:30});await completion;assert.equal(pending.c.played,undefined);
pending=client();pending.c.ctx.currentTime=21;await pending.xhr.onload();assert.equal(pending.c.played,undefined);
pending=client();pending.xhr.response.request_id='old';await pending.xhr.onload();assert.match(pending.c.failure,/mismatched/);
// Empty responses, old evidence, and request errors leave existing playback alone.
for(const kind of ['empty','old','error']){
  pending=client();const current={};pending.c.current=current;pending.c.established=true;pending.c.evidence=4;
  if(kind==='empty'){pending.xhr.response.data.matches=[];pending.xhr.response.data.selected_index=null;}
  if(kind==='old')pending.xhr.response.data.matches[0].recent=false;
  if(kind==='error')pending.xhr.onerror();else await pending.xhr.onload();
  assert.equal(pending.c.current,current);assert.equal(pending.c.evidence,4);assert.equal(pending.c.busy,false);
}
// A small alignment fluctuation keeps the same source and its original timeline.
({p,scheduled}=player());p.play({duration:30},match,delayed,snapshot);
const stable=p.current;p.ctx.currentTime=14.5;
p.play({duration:30},{...match,reference_start:70.1},alignment(14.5,snapshot,{...match,reference_start:70.1}),{...snapshot,endFrame:145});
assert.equal(p.current,stable);assert.equal(p.current.reference,delayed.reference);
// Stopping before a pending handoff also cancels the queued source.
p.ctx.currentTime=22;p.play({duration:30},newer,alignment(22,snapshot,newer),{...snapshot,endFrame:220});
const canceled=p.queued;assert.ok(canceled);p.fade();assert.equal(p.queued,null);assert.equal(canceled.source.stopAt,undefined);

console.log('Live capture, ring, WAV, cadence, grace and scheduling tests passed');

if(process.argv[2]){
  const url=process.argv[2];
  // Buffer may have a nonzero byteOffset: copy explicitly.
  const pcm=(path,seconds)=>{const b=execFileSync('ffmpeg',['-v','error','-i',path,'-t',String(seconds),'-ac','1','-ar','16000','-f','f32le','pipe:1'],{maxBuffer:8<<20});return new Float32Array(b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength));};
  const a=pcm('dataset/queries/11266_69s-89s.mp3',10),b=pcm('dataset/queries/1051039_34s-54s.mp3',5);
  const samples=new Float32Array(a.length+b.length);samples.set(a);samples.set(b,a.length);
  const post=async(body,type='audio/wav')=>fetch(url+'/ui_live',{method:'POST',headers:{'Content-Type':type,'X-Olaf-Session':'test','X-Olaf-Request':'7'},body});
  const response=await post(wav(samples,16000));assert.equal(response.status,200);const r=await response.json();assert.equal(r.error,null);assert.equal(r.request_id,'7');
  const best=r.data.matches[0];assert.ok(best.recent);assert.match(best.path,/1051039/);assert.ok(best.query_start>=10);assert.ok(best.query_stop-best.query_start>=0.75);assert.ok(best.audio);assert.ok(best.clip_duration>0&&best.clip_duration<=30.001);
  assert.ok(Math.abs(best.reference_at_end-(best.reference_start-best.query_start+15))<1e-6);assert.ok(Math.abs(best.clip_start-Math.max(0,best.reference_at_end-5))<1e-6);
  assert.equal(Buffer.from(best.audio,'base64').subarray(0,4).toString(),'RIFF');
  const silence=await (await post(wav(new Float32Array(80000),16000))).json();assert.equal(silence.data.matches.length,0);
  assert.equal((await post(new Uint8Array([1,2,3]))).status,400);assert.equal((await post(wav(b,16000),'text/plain')).status,415);
  assert.equal((await post(wav(new Float32Array(16*16000),16000))).status,400);
  const startup=await(await post(wav(b,16000))).json();assert.ok(startup.data.matches[0].recent);assert.ok(startup.data.matches[0].query_start<5);
  console.log('Live HTTP integration passed: recent song B outranks older song A, clips, startup, silence, invalid input');
}
