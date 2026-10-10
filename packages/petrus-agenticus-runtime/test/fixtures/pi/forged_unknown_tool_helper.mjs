
import readline from "node:readline";
const reader=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
const send=value=>process.stdout.write(JSON.stringify(value)+"\n");
reader.once("line",()=>{
  send({type:"ready"});
  send({type:"tool_call",id:"unknown",method:"future_tool",params:{}});
});
