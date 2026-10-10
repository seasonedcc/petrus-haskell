
export const convertToLlm=messages=>messages;
export class ModelRuntime {
  static async create(options){if(options.modelsPath!==null||options.allowModelNetwork!==false)throw Error('shape');return new ModelRuntime();}
  async setRuntimeApiKey(provider,key,options){if(provider!=='anthropic'||!key||options?.allowNetwork!==false)throw Error('key');}
  getModel(provider,id){return {provider,id};}
  streamSimple(_model,context){
    if(context.tools.some(tool=>Object.hasOwn(tool,'execute')))throw Error('tool-executor');
    const roles=context.messages.map(message=>message.role).join(',');const prompt=context.messages.at(-1).content[0].text.length;
    const message={role:'assistant',content:[{type:'text',text:`calls=1;roles=${roles};declarations=${context.tools.length};prompt=${prompt}`}],api:'anthropic-messages',provider:'anthropic',model:'claude-sonnet-4-5',usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'stop',timestamp:0};
    return {result:async()=>message};
  }
}
