export async function runAgentLoop(prompts,context,config,emit,signal,streamFn) {
  if (arguments.length !== 6 || config.shouldStopAfterTurn() !== true || context.messages.length !== 1) throw Error('shape');
  const observation=prompts[0].content[0].text;
  if (observation === 'blocked') {
    const args={path:'message.txt',content:'after'};
    const blocked=await config.beforeToolCall({toolCall:{id:'blocked-call',name:'workspace_write',arguments:args},args,context},signal);
    if (!blocked?.block) throw Error('guard');
  } else {
    const tool=config.tools.find(candidate=>candidate.name==='workspace_read');
    await tool.execute('read-call',{path:'message.txt'},signal);
    if (observation === 'overflow') await tool.execute('read-call-2',{path:'message.txt'},signal);
  }
  return [prompts[0],{role:'assistant',content:[{type:'text',text:observation}],stopReason:'stop'}];
}
