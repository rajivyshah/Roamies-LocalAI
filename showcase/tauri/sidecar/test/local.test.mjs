// The user's own model servers: the list of endpoints, the probe, and the models that come back.
import assert from 'node:assert/strict';
import http from 'node:http';
import { getAuthStorageKeys, getModel } from '@kenkaiiii/gg-core';
import { LOCAL_KINDS, LOCAL_PROVIDER, discoverLocal, endpointOf, endpointsToProbe, endpointsWithModels, newEndpointId, registerLocalModels } from '../local.mjs';

// ---------- names ----------
{
  assert.equal(newEndpointId('My server'), 'my-server');
  assert.equal(newEndpointId('Ollama on my box'), 'ollama-on-my-box');
  assert.equal(newEndpointId(''), 'server');
  assert.equal(newEndpointId('Ollama', ['ollama']), 'ollama-2', 'a second one gets its own name');
  assert.equal(newEndpointId('Ollama', ['ollama', 'ollama-2']), 'ollama-3');
}
console.log('endpoint names: passed');

// ---------- the list of endpoints ----------
{
  const saved = [{ id: 'mybox', label: 'My box', kind: 'custom', baseUrl: 'http://127.0.0.1:8080/v1' }];
  const all = endpointsToProbe(saved);
  assert.equal(all[0].id, 'mybox', 'the saved one comes first');
  assert.equal(all[0].custom, true);
  assert.ok(all.some((e) => e.id === 'ollama'), 'Ollama is looked for by itself');
  assert.equal(all.filter((e) => e.id === 'ollama').length, 1, 'never twice');
  assert.equal(endpointsToProbe([{ id: 'ollama', label: 'Mine', kind: 'ollama', baseUrl: 'http://127.0.0.1:11434/v1' }]).length, 1, 'a saved Ollama is not added again');
}
console.log('endpoint list: passed');

// ---------- the kinds there are ----------
{
  const ids = LOCAL_KINDS.map((k) => k.id);
  assert.deepEqual(ids, ['ollama', 'lmstudio', 'llamacpp', 'vllm', 'custom']);
  for (const k of LOCAL_KINDS) assert.ok(k.label && k.hint.includes('http'), 'each kind says where it usually sits');
}
console.log('kinds: passed');

// ---------- a server that answers ----------
{
  // A small OpenAI-compatible server: it lists two models and nothing else.
  const server = http.createServer((req, res) => {
    if (req.url.endsWith('/models')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ data: [{ id: 'tiny-1b' }, { id: 'embed-small' }] }));
    }
    res.writeHead(404); res.end('no');
  });
  await new Promise((r) => server.listen(0, r));
  const baseUrl = `http://127.0.0.1:${server.address().port}/v1`;
  const saved = [{ id: 'testbox', label: 'Test box', kind: 'custom', baseUrl }];
  const { probes, models } = await discoverLocal(saved, { force: true });
  server.close();

  const probe = probes.find((p) => p.endpoint.id === 'testbox');
  assert.equal(probe.reachable, true, 'the server answered');
  assert.deepEqual(probe.models.map((m) => m.rawId), ['tiny-1b'], 'the embedding model is not a chat model');
  // The models are known to the framework now, under "local/<endpoint>/<name>".
  assert.equal(getModel('local/testbox/tiny-1b')?.provider, LOCAL_PROVIDER);
  assert.deepEqual(getAuthStorageKeys(LOCAL_PROVIDER, 'local/testbox/tiny-1b'), ['local:testbox'], 'it runs on that endpoint credential');
  assert.ok(models.some((m) => m.id === 'local/testbox/tiny-1b'));

  // What the panel shows.
  const shown = endpointsWithModels(probes);
  const box = shown.find((e) => e.id === 'testbox');
  assert.equal(box.label, 'Test box');
  assert.equal(box.baseUrl, baseUrl);
  assert.equal(box.reachable, true);
  assert.deepEqual(box.models, [{ id: 'local/testbox/tiny-1b', name: 'tiny-1b' }]);
}
console.log('a server that answers: passed');

// ---------- a server that doesn't ----------
{
  const { probes } = await discoverLocal([{ id: 'gone', label: 'Gone', kind: 'custom', baseUrl: 'http://127.0.0.1:9/v1' }], { force: true });
  const probe = probes.find((p) => p.endpoint.id === 'gone');
  assert.equal(probe.reachable, false);
  assert.ok(probe.reason, 'it says why');
  assert.deepEqual(probe.models, []);
}
console.log('a server that does not answer: passed');

// ---------- which endpoint a model belongs to ----------
{
  assert.equal(endpointOf('local/ollama/qwen3.5:2b'), 'ollama');
  assert.equal(endpointOf('claude-haiku-5-5'), null);
  assert.equal(endpointOf(''), null);
}
console.log('model endpoint: passed');

// ---------- registering again leaves no old models behind ----------
{
  registerLocalModels([]);
  assert.equal(getModel('local/testbox/tiny-1b'), undefined, 'a model that is gone is gone');
}
console.log('re-registering: passed');

console.log('local endpoint tests: passed');
