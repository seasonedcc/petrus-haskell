
// A forged native helper that puts a lone surrogate escape ("\ud800", which
// JSON.stringify writes as such) into one member of one frame. The test
// replaces __SCENARIO__ before it runs the helper.
import readline from "node:readline";
const reader=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
const send=value=>process.stdout.write(JSON.stringify(value)+"\n");
const lone="\ud800";
const scenario="__SCENARIO__";
let start;
const finish=text=>{
  const body=Buffer.from(JSON.stringify({type:"session",version:3,id:start.session_id})+"\n").toString("base64");
  const complete={type:"complete",session_id:start.session_id,text,session:body};
  process.stdout.write(JSON.stringify(complete)+"\n",()=>process.exit(0));reader.close();
};
reader.on("line",line=>{
  const frame=JSON.parse(line);
  if(!start){
    start=frame;
    if(scenario==="member"){send({type:"ready",[lone]:true});return;}
    send({type:"ready"});
    if(scenario==="params"||scenario==="echo")send({type:"tool_call",id:"call",method:"workspace_read",params:{path:"/"+lone}});
    else if(scenario==="identity")send({type:"tool_call",id:lone,method:"workspace_read",params:{path:"marker.txt"}});
    else if(scenario==="method")send({type:"tool_call",id:"call",method:"workspace_read"+lone,params:{path:"marker.txt"}});
    else if(scenario==="text")finish(lone);
    else if(scenario==="type")send({type:lone});
    else if(scenario==="code")send({type:"failed",code:lone});
    else throw new Error("scenario");
    return;
  }
  if(frame.type!=="tool_result"||frame.id!=="call")throw new Error("protocol");
  finish("answer");
});
