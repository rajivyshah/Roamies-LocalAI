// The user's own model servers: Ollama, LM Studio, llama.cpp, vLLM, or any OpenAI-compatible URL.
//
// The framework already knows how to find the models on one (gg-core's discoverLocalModels) and how to
// talk to one (gg-ai's "local" provider, which is the OpenAI-compatible transport). This is the small
// piece in between: the list of endpoints, the probe, and the models that come back.
//
// A model on one of these is called "local/<endpoint>/<the name on the wire>" — for example
// "local/ollama/qwen3.5:2b" — and its credential lives under "local:<endpoint>" in ~/.gg/auth.json,
// next to the sign-ins. The app picks it up from there like any other provider.
import { DEFAULT_LOCAL_ENDPOINTS, clearRuntimeModels, discoverLocalModels, formatLocalModelId, registerRuntimeModels, setProviderCatalog } from '@kenkaiiii/gg-core';

export const LOCAL_PROVIDER = 'local';

/** The servers found without being asked for (Ollama). One that answers is saved, so it can be used at once. */
export const isDefaultEndpoint = (id) => DEFAULT_LOCAL_ENDPOINTS.some((e) => e.id === id);

// The kinds of server there are, and where they usually sit.
export const LOCAL_KINDS = [
  { id: 'ollama', label: 'Ollama', hint: 'http://127.0.0.1:11434/v1' },
  { id: 'lmstudio', label: 'LM Studio', hint: 'http://127.0.0.1:1234/v1' },
  { id: 'llamacpp', label: 'llama.cpp', hint: 'http://127.0.0.1:8080/v1' },
  { id: 'vllm', label: 'vLLM', hint: 'http://127.0.0.1:8000/v1' },
  { id: 'custom', label: 'Custom (OpenAI-compatible)', hint: 'http://127.0.0.1:8080/v1' },
];

/** A short id for a new endpoint, from its name: "My server" → "my-server". */
export function newEndpointId(label, taken = []) {
  const base = String(label ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || 'server';
  let id = base, n = 2;
  while (taken.includes(id)) id = `${base}-${n++}`;
  return id;
}

/** The endpoints to look at: the ones the user saved, plus Ollama (the one server found by itself). */
export function endpointsToProbe(saved = []) {
  const out = saved.map((s) => ({ id: s.id, label: s.label || s.id, baseUrl: s.baseUrl, kind: s.kind || 'custom', custom: true }));
  for (const d of DEFAULT_LOCAL_ENDPOINTS) if (!out.some((e) => e.id === d.id)) out.push({ ...d });
  return out;
}

/** Make the models known to the framework, so getModel() and the auth keys work for them. */
export function registerLocalModels(models = []) {
  clearRuntimeModels(); // a server that was stopped doesn't leave its models behind
  setProviderCatalog(LOCAL_PROVIDER, models);
  registerRuntimeModels(models);
}

/**
 * Look at every endpoint and register the models they serve.
 * Resolves { probes, models }: the probes say which servers answered, the models are the framework's
 * own model records (already named "local/<endpoint>/<model>").
 */
export async function discoverLocal(saved = [], { force = false, register = true } = {}) {
  const { probes, models } = await discoverLocalModels(endpointsToProbe(saved), { force });
  if (register) registerLocalModels(models);
  return { probes, models };
}

/** Each endpoint, as the panel shows it: its address, whether it answered, and the models it serves. */
export function endpointsWithModels(probes = []) {
  return probes.map((p) => ({
    id: p.endpoint.id,
    label: p.endpoint.label,
    kind: p.endpoint.kind,
    baseUrl: p.endpoint.baseUrl,
    reachable: !!p.reachable,
    reason: p.reason ?? null,
    models: (p.models ?? []).map((m) => ({ id: formatLocalModelId(p.endpoint.id, m.rawId), name: m.rawId })),
  }));
}

/** The models of the endpoint a model id belongs to ("local/ollama/qwen3.5:2b" → "ollama"). */
export function endpointOf(modelId) {
  const rest = String(modelId ?? '').split('/');
  return rest.length > 2 && rest[0] === LOCAL_PROVIDER ? rest[1] : null;
}
