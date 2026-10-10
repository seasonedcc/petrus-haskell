
import fs from "node:fs";
import path from "node:path";
export class ModelRuntime {
  static async create() { return new ModelRuntime(); }
  async setRuntimeApiKey(provider, key) { if (provider !== "provider" || key !== "pi-key-canary-never-render") throw new Error(); }
  getModel(provider, id) { return {provider, id}; }
}
export class SettingsManager { static inMemory(value) { return value; } }
export class DefaultResourceLoader { constructor(options) { this.options=options; } async reload() {} getExtensions(){return {extensions:[],errors:[]};} }
class Manager {
  constructor(cwd, directory, id, file=null) { this.cwd=cwd; this.directory=directory; this.id=id; this.file=file || path.join(directory,"native.jsonl"); }
  getSessionFile() { return this.file; }
}
export class SessionManager {
  static create(cwd, directory, options) { return new Manager(cwd,directory,options.id); }
  static open(file, directory, cwd) { const header=JSON.parse(fs.readFileSync(file,"utf8").split("\n")[0]); return new Manager(cwd,directory,header.id,file); }
  static inMemory(cwd, options) { return new Manager(cwd,cwd,options.id); }
}
export const defineTool = tool => tool;
export async function createAgentSession(options) {
  const state={messages:[]}; const listeners=[];
  const session={
    state,
    subscribe(listener) { listeners.push(listener); return ()=>{}; },
    async prompt() {
      const tool=options.customTools.find(value=>value.name==="workspace_read");
      const resumed=fs.existsSync(options.sessionManager.getSessionFile());
      const callId=resumed?"provider-tool-call-resumed":"provider-tool-call";
      const result=await tool.execute(callId,{path:"marker.txt"},undefined);
      const projected=JSON.parse(result.content[0].text);
      if(Object.keys(projected).sort().join()!=="data,error,ok,version"||projected.version!==1||projected.ok!==true||projected.error!==null||!projected.data?.content?.includes("marker")) throw new Error();
      state.messages=[{role:"assistant",stopReason:"stop",content:[{type:"text",text:"protocol-answer"}]}];
      const header={type:"session",version:3,id:options.sessionManager.id};
      const file=options.sessionManager.getSessionFile();
      if(!fs.existsSync(file))fs.writeFileSync(file,JSON.stringify(header)+"\n",{mode:0o600,flag:"wx"});
      fs.appendFileSync(file,JSON.stringify({type:"message",role:"tool",toolCallId:callId,result:projected})+"\n");
      for(const listener of listeners) listener({type:"agent_end"});
    },
    async waitForIdle() {}, async abort() {}, dispose() {},
  };
  return {session};
}
