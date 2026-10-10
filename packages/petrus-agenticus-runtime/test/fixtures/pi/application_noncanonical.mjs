import readline from 'node:readline';
const reader=readline.createInterface({input:process.stdin});
reader.once('line',()=>{process.stdout.write('{"type":"ready"}\n{"type":"complete","text":"done","transcript":"W10=="}\n');reader.close();});
