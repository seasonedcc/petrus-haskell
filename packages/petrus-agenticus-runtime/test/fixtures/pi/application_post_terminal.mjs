import readline from 'node:readline';
const reader=readline.createInterface({input:process.stdin});
reader.once('line',()=>{process.stdout.write('{"type":"ready"}\n{"type":"complete","text":"done","transcript":"W10="}\n{"type":"tool_call","id":"late","method":"workspace_read","params":{"path":"message.txt"}}\n');});
