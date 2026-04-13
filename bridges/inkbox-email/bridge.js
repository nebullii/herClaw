#!/usr/bin/env node
// Inkbox email <-> OpenClaw bridge.
//
// Flow: Inkbox mailbox webhook -> POST /webhook -> run `openclaw agent`
// keyed by sender email -> reply via `inkbox email send`.
//
// Config (env):
//   INKBOX_API_KEY        (required)
//   INKBOX_IDENTITY       default: herClaw
//   INKBOX_BASE_URL       default: https://inkbox.ai
//   OPENCLAW_CONTAINER    default: openclaw-agent
//   PORT                  default: 3838

const http = require('http');
const { spawnSync } = require('child_process');

const PORT = Number(process.env.PORT || 3838);
const IDENTITY = process.env.INKBOX_IDENTITY || 'herClaw';
const BASE_URL = process.env.INKBOX_BASE_URL || 'https://inkbox.ai';
const CONTAINER = process.env.OPENCLAW_CONTAINER || 'openclaw-agent';
const OWN_MAILBOX = (process.env.INKBOX_MAILBOX || '').toLowerCase();

if (!process.env.INKBOX_API_KEY) {
  console.error('INKBOX_API_KEY not set');
  process.exit(1);
}

function log(...a) {
  console.log(new Date().toISOString(), ...a);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', c => { data += c; if (data.length > 2_000_000) req.destroy(); });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

function askAgent(fromEmail, messageText) {
  const r = spawnSync('docker', [
    'exec', '-i', CONTAINER,
    'openclaw', 'agent',
    '--to', fromEmail,
    '--message', messageText,
    '--json',
    '--timeout', '120',
  ], { encoding: 'utf8', timeout: 180_000 });
  if (r.error) throw r.error;
  if (r.status !== 0) throw new Error(`openclaw agent exited ${r.status}: ${r.stderr}`);
  try {
    const j = JSON.parse(r.stdout);
    const payloads = j?.result?.payloads;
    if (Array.isArray(payloads) && payloads.length) {
      const text = payloads.map(p => p?.text).filter(Boolean).join('\n\n');
      if (text) return text;
    }
    return j.reply || j.text || j.message || r.stdout.trim();
  } catch {
    return r.stdout.trim();
  }
}

function sendEmail(to, subject, body) {
  const r = spawnSync('inkbox', [
    'email', 'send',
    '-i', IDENTITY,
    '--base-url', BASE_URL,
    '--to', to,
    '--subject', subject,
    '--body-html', `<p>${body.replace(/</g, '&lt;').replace(/\n/g, '<br>')}</p>`,
  ], { encoding: 'utf8', timeout: 30_000 });
  if (r.status !== 0) throw new Error(`inkbox send exited ${r.status}: ${r.stderr}`);
  return r.stdout.trim();
}

function fetchFullBody(id) {
  const r = spawnSync('inkbox', [
    '--base-url', BASE_URL, '--json',
    'email', 'get', id, '-i', IDENTITY,
  ], { encoding: 'utf8', timeout: 15_000 });
  if (r.status !== 0) return '';
  try {
    const j = JSON.parse(r.stdout);
    return j.bodyText || j.body_text || j.bodyHtml || j.body_html || '';
  } catch { return ''; }
}

function extract(payload) {
  // Inkbox webhook shape: { data: { message: {...} }, event_type, timestamp }
  const m = payload?.data?.message;
  if (!m) return {};
  if (m.direction && m.direction !== 'inbound') return { direction: m.direction };
  const from = (m.from_address || m.fromAddress || '').toString();
  if (OWN_MAILBOX && from.toLowerCase() === OWN_MAILBOX) return { selfLoop: true, from };
  const subject = m.subject || '(no subject)';
  let body = m.body_text || m.bodyText || m.snippet || '';
  if (!body && m.id) body = fetchFullBody(m.id);
  return { from, subject, body };
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  if (req.method !== 'POST' || req.url !== '/webhook') {
    res.writeHead(404); res.end('not found'); return;
  }
  try {
    const raw = await readBody(req);
    let payload;
    try { payload = JSON.parse(raw); }
    catch { log('non-JSON body', raw.slice(0, 400)); res.writeHead(400); res.end('bad json'); return; }
    log('webhook payload keys:', Object.keys(payload));
    const info = extract(payload);
    const { from, subject, body, direction, selfLoop } = info;
    if (selfLoop) { log('skip self-loop from', from); res.writeHead(200); res.end('{}'); return; }
    if (direction && direction !== 'inbound') { log('skip non-inbound', direction); res.writeHead(200); res.end('{}'); return; }
    if (!from || !body) {
      log('missing from/body', { from, subjectLen: subject?.length, bodyLen: body?.length, raw: raw.slice(0, 400) });
      res.writeHead(202); res.end('ignored'); return;
    }
    log('from', from, 'subject', subject, 'bodyLen', body.length);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ accepted: true }));
    // Process asynchronously after we ack the webhook.
    setImmediate(async () => {
      try {
        const reply = askAgent(from, body);
        log('agent reply len', reply.length);
        const sendOut = sendEmail(from, subject.startsWith('Re:') ? subject : `Re: ${subject}`, reply);
        log('sent', sendOut.split('\n')[0]);
      } catch (e) {
        log('handler error:', e.message);
      }
    });
  } catch (e) {
    log('server error:', e.message);
    if (!res.headersSent) { res.writeHead(500); res.end('error'); }
  }
});

server.listen(PORT, '127.0.0.1', () => {
  log(`inkbox email bridge listening on 127.0.0.1:${PORT}`);
});
