
import fs from "node:fs";
import path from "node:path";
const EXPECTED_AUTH="__EXPECTED_AUTH__", REFRESHED_AUTH="__REFRESHED_AUTH__", PROVIDER="__PROVIDER__", MODEL="__MODEL__", FAIL=__FAIL__;
export class ModelRuntime {
  constructor(authPath) { this.authPath=authPath; }
  static async create(options) {
    const metadata=fs.statSync(options.authPath);
    if(options.modelsPath!==null||options.allowModelNetwork!==false||(metadata.mode&0o777)!==0o600||fs.readFileSync(options.authPath).toString("base64")!==EXPECTED_AUTH)throw new Error("auth");
    return new ModelRuntime(options.authPath);
  }
  async setRuntimeApiKey() { throw new Error("api-key-forbidden"); }
  async listCredentials() { return [{providerId:PROVIDER,type:"oauth"}]; }
  isUsingOAuth(provider) { return provider===PROVIDER; }
  getModel(provider,id) { return provider===PROVIDER&&id===MODEL?{provider,id}:undefined; }
}
export class SettingsManager { static inMemory(value) { return value; } }
export class DefaultResourceLoader { constructor(options) { this.options=options; } async reload() {} getExtensions(){return {extensions:(this.options.additionalExtensionPaths||[]).map(resolvedPath=>({resolvedPath})),errors:[]};} }
class Manager {
  constructor(cwd,directory,id,file=null){this.cwd=cwd;this.directory=directory;this.id=id;this.file=file||path.join(directory,"native.jsonl");}
  getSessionFile(){return this.file;}
}
export class SessionManager {
  static create(cwd,directory,options){return new Manager(cwd,directory,options.id);}
  static open(file,directory,cwd){const header=JSON.parse(fs.readFileSync(file,"utf8").split("\n")[0]);return new Manager(cwd,directory,header.id,file);}
  static inMemory(cwd,options){return new Manager(cwd,cwd,options.id);}
}
export const defineTool=tool=>tool;
export async function createAgentSession(options){
  const state={messages:[]};
  const session={
    state,subscribe(){return ()=>{};},
    async prompt(){
      const tool=options.customTools.find(value=>value.name==="workspace_read");
      const result=await tool.execute("subscription-tool-call",{path:"marker.txt"},undefined);
      if(!result.content[0].text.includes("marker"))throw new Error("provider");
      fs.rmSync(options.modelRuntime.authPath);
      fs.writeFileSync(options.modelRuntime.authPath,Buffer.from(REFRESHED_AUTH,"base64"),{mode:__MODE__,flag:"wx"});
      fs.chmodSync(options.modelRuntime.authPath,__MODE__);
      if(FAIL)throw new Error("provider");
      state.messages=[{role:"assistant",stopReason:"stop",content:[{type:"text",text:"subscription-answer"}]}];
      const header={type:"session",version:3,id:options.sessionManager.id};
      fs.writeFileSync(options.sessionManager.getSessionFile(),JSON.stringify(header)+"\n",{mode:0o600});
    },
    async waitForIdle(){},async abort(){},dispose(){},
  };
  return {session};
}
