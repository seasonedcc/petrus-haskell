import readline from 'node:readline';
const reader=readline.createInterface({input:process.stdin});let first=true;
reader.on('line',line=>{if(first){first=false;process.stdout.write('{"type":"ready"}\n');}else{process.stdout.write('{"type":"complete","text":"late","transcript":"W10="}\n');}});
