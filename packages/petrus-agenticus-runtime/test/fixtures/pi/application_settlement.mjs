// A forged A5 application helper for the settlement edges where the
// reference raises something other than RuntimeProtocolError: a helper that
// outlives the grace (subprocess.TimeoutExpired) and a list or dict where a
// set-membership test needs a hashable value (TypeError). Both the reference
// script (application-settlement-reference.py) and PiApplicationSpec replace
// __SCENARIO__ before they run it.
import readline from "node:readline";
const reader=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
const send=value=>process.stdout.write(JSON.stringify(value)+"\n");
const scenario="__SCENARIO__";
const base64=value=>Buffer.from(JSON.stringify(value)).toString("base64");
const complete=JSON.stringify({type:"complete",text:"done",transcript:base64([])})+"\n";
const call=method=>({type:"tool_call",id:"call",method,params:{path:"message.txt"}});
reader.once("line",()=>{
  if(scenario==="method-list-unready"){send(call([]));return;}
  send({type:"ready"});
  // The terminal frame, then the helper stays alive (its stdin stays open).
  if(scenario==="exit-timeout")process.stdout.write(complete);
  else if(scenario==="exit-nonzero")process.stdout.write(complete,()=>process.exit(3));
  else if(scenario==="type-list")send({type:[]});
  else if(scenario==="type-dict")send({type:{}});
  else if(scenario==="code-list")send({type:"failed",code:[]});
  else if(scenario==="code-dict")send({type:"failed",code:{}});
  else if(scenario==="code-list-extra")send({type:"failed",code:[],extra:1});
  else if(scenario==="method-list")send(call([]));
  else if(scenario==="method-dict")send(call({}));
  else if(scenario==="method-number")send(call(1));
  else if(scenario==="method-list-long-id")send({...call([]),id:"x".repeat(129)});
  else throw new Error("scenario");
});
