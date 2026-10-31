#!/usr/bin/env node
// The mainnet fork's upstream (local/up.sh in fork mode points anvil's --fork-url here): a JSON-RPC relay on 127.0.0.1
// that sends every request to Robinhood Chain's own public RPC and retries on a public archive RPC only what the
// first can't answer. Robinhood's RPC keeps state for ~6000 blocks (~10 minutes), and anvil fetches the fork block's
// state lazily, so after that every storage slot the fork hasn't read yet fails ("historical state … is not
// available"); the archive RPC serves old state but refuses log ranges over 10k blocks, which Robinhood's answers
// (the site reads HoodLock's locks in 10M-block windows). Neither alone keeps a fork usable; together they do. Both are
// keyless public endpoints: never put a keyed provider here (its key would sit in anvil's arguments and logs).
//   node local/fork-rpc.mjs <port> <primary url> <archive url>
import { createServer } from 'node:http'

const [port, primary, archive] = process.argv.slice(2)
if (!port || !primary || !archive) {
    console.error('[fork-rpc] usage: fork-rpc.mjs <port> <primary url> <archive url>')
    process.exit(1)
}

// the primary's answers that mean "too old for me", worth asking the archive
const STALE_STATE = /historical state|not available|missing trie node|header not found|state.*pruned/i
const TIMEOUT_MS = 60_000

/** Posts a JSON-RPC body upstream. @returns the HTTP status and parsed JSON (null when it isn't JSON) */
async function post(url, body) {
    const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(TIMEOUT_MS),
    })
    const text = await res.text()
    try {
        return { status: res.status, json: JSON.parse(text) }
    } catch {
        return { status: res.status, json: null, text }
    }
}

/** One request: the primary's answer, or the archive's when the primary's is about state it no longer has. */
async function relay(request) {
    let first
    try {
        first = await post(primary, request)
    } catch (err) {
        console.error('[fork-rpc] primary', request.method, err.message)
    }
    const isStale = !first || first.status === 429 || first.status >= 500 || !first.json
        || (first.json.error && STALE_STATE.test(first.json.error.message ?? ''))
    if (!isStale) return first.json
    try {
        const second = await post(archive, request)
        if (second.json) return second.json
        console.error('[fork-rpc] archive', request.method, second.status, (second.text ?? '').slice(0, 200))
    } catch (err) {
        console.error('[fork-rpc] archive', request.method, err.message)
    }
    // both failed: the primary's own error, so anvil reports the real cause
    return first?.json ?? { jsonrpc: '2.0', id: request.id ?? null, error: { code: -32000, message: 'fork upstreams unavailable' } }
}

const server = createServer(async (req, res) => {
    let body = ''
    for await (const chunk of req) body += chunk
    let payload
    try {
        payload = JSON.parse(body)
    } catch (err) {
        res.writeHead(400, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: `parse error: ${err.message}` } }))
        return
    }
    // a batch is relayed request by request, so one stale entry doesn't send the whole batch to the archive
    const answer = Array.isArray(payload) ? await Promise.all(payload.map(relay)) : await relay(payload)
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(answer))
})
server.listen(Number(port), '127.0.0.1', () => console.log(`[fork-rpc] 127.0.0.1:${port} → ${primary} (archive ${archive})`))
