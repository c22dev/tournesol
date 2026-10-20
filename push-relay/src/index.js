// Relays Live Activity pushes from Tournesol devices to APNs.
// Secrets: APNS_KEY (contents of the .p8), APNS_KEY_ID, RELAY_SECRET.
// Route: POST /send.
// Errors are JSON: { error, message, reason? }.

let cachedJWT = null

// Best-effort, per-isolate limit: Live Activity updates are bursty, but a runaway client shouldn't hammer APNs.
const WINDOW_MS = 60_000
const MAX_PER_WINDOW = 60
const recent = new Map()

const REASONS = {
  BadDeviceToken: 'The push token is invalid or was issued for a different environment (sandbox vs production).',
  DeviceTokenNotForTopic: 'The push token does not belong to this app. Check the bundle ID and APNS_TOPIC_PREFIX.',
  ExpiredToken: 'The Live Activity ended or its push token expired.',
  Unregistered: 'The Live Activity ended or its push token expired.',
  TopicDisallowed: 'This APNs key is not allowed to push to that topic. Check the bundle ID.',
  InvalidProviderToken: 'APNs rejected the signing key. Check APNS_KEY, APNS_KEY_ID and APNS_TEAM_ID.',
  ExpiredProviderToken: 'APNs rejected the signing token as expired.',
  BadTopic: 'The apns-topic is malformed.',
  MissingTopic: 'The apns-topic is missing.',
  PayloadTooLarge: 'The Live Activity payload exceeds 4 KB.',
  TooManyRequests: 'APNs is throttling pushes to this device.',
}

function json(status, body, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } })
}

function rateLimited(key, now) {
  const hits = (recent.get(key) ?? []).filter((time) => now - time < WINDOW_MS)
  hits.push(now)
  recent.set(key, hits)
  if (recent.size > 500) {
    for (const [other, times] of recent) if (now - times[times.length - 1] > WINDOW_MS) recent.delete(other)
  }
  return hits.length > MAX_PER_WINDOW
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname
    if (request.method !== 'POST' || path !== '/send') return json(404, { error: 'not_found', message: 'Unknown route.' })
    // an unset secret must not match the header "Bearer undefined"
    if (!env.RELAY_SECRET || request.headers.get('authorization') !== `Bearer ${env.RELAY_SECRET}`) {
      return json(401, { error: 'unauthorized', message: 'The relay secret does not match PUSH_RELAY_SECRET.' })
    }
    let body
    try {
      body = await request.json()
    } catch {
      return json(400, { error: 'bad_json', message: 'The request body is not valid JSON.' })
    }
    const { token, environment, topic, priority, payload } = body
    if (!/^[0-9a-f]{32,200}$/i.test(token ?? '')) return json(400, { error: 'bad_token', message: 'The push token is not a hex string.' })
    if (!topic?.startsWith(env.APNS_TOPIC_PREFIX)) {
      return json(400, { error: 'bad_topic', message: `The topic must start with ${env.APNS_TOPIC_PREFIX}.` })
    }
    if (typeof payload !== 'object' || payload === null) return json(400, { error: 'bad_payload', message: 'The payload must be an object.' })
    if (rateLimited(token, Date.now())) {
      return json(429, { error: 'rate_limited', message: `More than ${MAX_PER_WINDOW} pushes per minute for this token.` }, { 'retry-after': '10' })
    }

    const host = environment === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com'
    let response
    try {
      response = await fetch(`https://${host}/3/device/${token}`, {
        method: 'POST',
        headers: {
          authorization: `bearer ${await jwt(env)}`,
          'apns-topic': topic,
          // the relay only carries Live Activity pushes, whatever the caller asks for
          'apns-push-type': 'liveactivity',
          'apns-priority': priority === 5 ? '5' : '10',
          'content-type': 'application/json',
        },
        body: JSON.stringify(payload),
      })
    } catch (error) {
      return json(502, { error: 'apns_unreachable', message: `Could not reach APNs (${error.message}).` })
    }

    const apnsID = response.headers.get('apns-id') ?? ''
    if (response.ok) return json(200, {}, { 'apns-id': apnsID })

    const text = await response.text()
    let reason = ''
    try {
      reason = JSON.parse(text).reason ?? ''
    } catch {}
    if (reason === 'InvalidProviderToken' || reason === 'ExpiredProviderToken') {
      cachedJWT = null
      await caches.default.delete(new Request(`https://jwt.tournesol.internal/${env.APNS_KEY_ID}`))
    }
    return json(response.status, { error: reason || 'apns_error', message: REASONS[reason] ?? (reason || `APNs returned ${response.status}.`), reason }, { 'apns-id': apnsID })
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
