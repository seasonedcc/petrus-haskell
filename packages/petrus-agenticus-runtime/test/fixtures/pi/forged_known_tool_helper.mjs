
import readline from "node:readline";
const reader=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
const send=value=>process.stdout.write(JSON.stringify(value)+"\n");
let start;
reader.on("line",line=>{
  const frame=JSON.parse(line);
  if(!start){
    start=frame;send({type:"ready"});
    send({type:"tool_call",id:"forged",method:"workspace_test",params:{}});return;
  }
  if(frame.type!=="tool_result")throw new Error("protocol");
  if(frame.id==="forged"){
    if(frame.result.ok||frame.result.error?.category!=="capability")throw new Error("authority");
    send({type:"tool_call",id:"allowed",method:"workspace_read",params:{path:"marker.txt"}});return;
  }
  if(frame.id!=="allowed"||!frame.result.ok||!frame.result.data?.content?.includes("marker"))
    throw new Error("read");
  const body=Buffer.from(JSON.stringify({type:"session",version:3,id:start.session_id})+"\n").toString("base64");
  const complete={type:"complete",session_id:start.session_id,text:"answer",session:body};
  process.stdout.write(JSON.stringify(complete)+"\n",()=>process.exit(0));reader.close();
});
