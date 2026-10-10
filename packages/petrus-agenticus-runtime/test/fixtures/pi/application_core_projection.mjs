export async function runAgentLoop(prompts,context,config,emit,signal,streamFn) {
  if (arguments.length !== 6 || config.shouldStopAfterTurn() !== true) throw Error('shape');
  const tool=config.tools.find(candidate=>candidate.name==='workspace_read');
  const callId=`read-${prompts[0].content[0].text}`;
  const result=await tool.execute(callId,{path:'message.txt'},signal);
  return [
    prompts[0],
    {role:'toolResult',toolCallId:callId,toolName:'workspace_read',content:result.content,isError:false,timestamp:0},
    {role:'assistant',content:[{type:'text',text:'done'}],stopReason:'stop',timestamp:0},
  ];
}
