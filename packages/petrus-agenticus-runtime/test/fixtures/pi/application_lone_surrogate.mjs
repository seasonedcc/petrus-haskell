
// A forged A5 application helper that puts a lone surrogate escape
// ("\ud800", which JSON.stringify writes as such) into one member of one
// frame. The test replaces __SCENARIO__ before it runs the helper.
import readline from "node:readline";
const reader=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
const send=value=>process.stdout.write(JSON.stringify(value)+"\n");
const lone="\ud800";
const scenario="__SCENARIO__";
const base64=value=>Buffer.from(JSON.stringify(value)).toString("base64");
let started=false;
const finish=(text,messages)=>{
  process.stdout.write(JSON.stringify({type:"complete",text,transcript:base64(messages)})+"\n",()=>process.exit(0));
  reader.close();
};
reader.on("line",line=>{
  const frame=JSON.parse(line);
  if(!started){
    started=true;
    if(scenario==="member"){send({type:"ready",[lone]:true});return;}
    send({type:"ready"});
    if(scenario==="params"||scenario==="echo")send({type:"tool_call",id:"call",method:"workspace_read",params:{path:"/"+lone}});
    else if(scenario==="identity")send({type:"tool_call",id:lone,method:"workspace_read",params:{path:"marker.txt"}});
    else if(scenario==="method")send({type:"tool_call",id:"call",method:"workspace_read"+lone,params:{path:"marker.txt"}});
    else if(scenario==="text")finish(lone,[]);
    else if(scenario==="transcript")finish("done",[{role:"user",content:lone}]);
    else if(scenario==="type")send({type:lone});
    else if(scenario==="code")send({type:"failed",code:lone});
    else throw new Error("scenario");
    return;
  }
  if(frame.type!=="tool_result"||frame.id!=="call")throw new Error("protocol");
  finish("done",[]);
});
