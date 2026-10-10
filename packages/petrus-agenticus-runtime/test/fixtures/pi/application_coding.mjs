export const convertToLlm=x=>x;
export class ModelRuntime {
  static async create(options) {
    if (options.modelsPath !== null || options.allowModelNetwork !== false) throw Error('shape');
    return new ModelRuntime();
  }
  async setRuntimeApiKey(provider,key) { if (provider !== 'anthropic' || !key) throw Error('key'); }
  getModel(provider,id) { return {provider,id}; }
  streamSimple() { throw Error('network'); }
}
