
import readline from "node:readline";
const reader=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
const send=value=>process.stdout.write(JSON.stringify(value)+"\n");
reader.once("line",line=>{
  const start=JSON.parse(line);
  const body=Buffer.from(JSON.stringify({type:"session",version:3,id:start.session_id})+"\n").toString("base64");
  send({type:"ready"});
  __TERMINAL__
});
