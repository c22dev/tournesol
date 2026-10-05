// Relays Live Activity pushes from Tournesol devices to APNs.
// Secrets: APNS_KEY (contents of the .p8), APNS_KEY_ID, RELAY_SECRET.

let cachedJWT = null

export default {
  async fetch(request, env) {
    if (request.method !== 'POST' || new URL(request.url).pathname !== '/send') {
      return new Response('not found', { status: 404 })
    }
    if (request.headers.get('authorization') !== `Bearer ${env.RELAY_SECRET}`) {
      return new Response('unauthorized', { status: 401 })
    }

    let body
    try {
      body = await request.json()
    } catch {
      return new Response('bad json', { status: 400 })
    }
    const { token, environment, topic, pushType, priority, payload } = body
    if (!/^[0-9a-f]{32,200}$/i.test(token ?? '') || !topic?.startsWith(env.APNS_TOPIC_PREFIX) || typeof payload !== 'object') {
      return new Response('bad request', { status: 400 })
    }

    const host = environment === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com'
    const response = await fetch(`https://${host}/3/device/${token}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${await jwt(env)}`,
        'apns-topic': topic,
        'apns-push-type': pushType ?? 'liveactivity',
        'apns-priority': String(priority ?? 10),
        'content-type': 'application/json',
      },
      body: JSON.stringify(payload),
    })
    return new Response(await response.text() || '{}', {
      status: response.status,
      headers: { 'content-type': 'application/json', 'apns-id': response.headers.get('apns-id') ?? '' },
    })
  },
}

async function jwt(env) {
  const now = Math.floor(Date.now() / 1000)
  if (cachedJWT && now - cachedJWT.issuedAt < 40 * 60) return cachedJWT.value

  const cacheKey = new Request(`https://jwt.tournesol.internal/${env.APNS_KEY_ID}`)
  const shared = await caches.default.match(cacheKey)
  if (shared) {
    const stored = await shared.json()
    if (now - stored.issuedAt < 40 * 60) {
      cachedJWT = stored
      return stored.value
    }
  }

  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0))
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])

  const encode = (value) => base64url(new TextEncoder().encode(JSON.stringify(value)))
  const unsigned = `${encode({ alg: 'ES256', kid: env.APNS_KEY_ID })}.${encode({ iss: env.APNS_TEAM_ID, iat: now })}`
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(unsigned))

  cachedJWT = { value: `${unsigned}.${base64url(new Uint8Array(signature))}`, issuedAt: now }
  await caches.default.put(cacheKey, new Response(JSON.stringify(cachedJWT), { headers: { 'cache-control': 'max-age=2400' } }))
  return cachedJWT.value
}

function base64url(bytes) {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}
