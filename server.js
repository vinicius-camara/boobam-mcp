'use strict';

const crypto  = require('crypto');
const express = require('express');
const mysql2  = require('mysql2/promise');
const jwt     = require('jsonwebtoken');

const app  = express();
const PORT = parseInt(process.env.PORT || '3000', 10);

const MYSQL_CFG = {
  host:               process.env.MYSQL_HOST || '127.0.0.1',
  port:               parseInt(process.env.MYSQL_PORT || '3307', 10),
  user:               process.env.MYSQL_USER || 'root',
  password:           process.env.MYSQL_PASS || '',
  database:           process.env.MYSQL_DB   || 'boobam',
  waitForConnections: true,
  connectionLimit:    5,
  connectTimeout:     10000,
};

// ── Fonte D0: Aurora de produção, endpoint reader (somente leitura) ──────────
// Configurada via D0_MYSQL_*; se D0_MYSQL_HOST não estiver definido, a fonte
// fica indisponível e as tools continuam operando apenas com a D-1.
const D0_CFG = process.env.D0_MYSQL_HOST ? {
  host:               process.env.D0_MYSQL_HOST,
  port:               parseInt(process.env.D0_MYSQL_PORT || '3306', 10),
  user:               process.env.D0_MYSQL_USER || MYSQL_CFG.user,
  password:           process.env.D0_MYSQL_PASS || '',
  database:           process.env.D0_MYSQL_DB   || MYSQL_CFG.database,
  waitForConnections: true,
  connectionLimit:    3,
  connectTimeout:     10000,
} : null;

const BEARER_TOKEN         = process.env.BEARER_TOKEN         || '';
const GOOGLE_CLIENT_ID     = process.env.GOOGLE_CLIENT_ID     || '';
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET || '';
const JWT_SECRET           = process.env.JWT_SECRET           || '';
const BASE_URL             = process.env.BASE_URL             || 'http://localhost:' + PORT;
const ALLOWED_EMAIL_DOMAIN = process.env.ALLOWED_EMAIL_DOMAIN || ''; // ex.: boobam.com.br (vazio = qualquer e-mail)

const OAUTH_ENABLED = !!(GOOGLE_CLIENT_ID && GOOGLE_CLIENT_SECRET && JWT_SECRET);

console.log('[config] MySQL D-1:', MYSQL_CFG.user + '@' + MYSQL_CFG.host + ':' + MYSQL_CFG.port + '/' + MYSQL_CFG.database);
console.log('[config] MySQL D0:', D0_CFG ? D0_CFG.user + '@' + D0_CFG.host + ':' + D0_CFG.port + '/' + D0_CFG.database + ' ✅' : '⚠️ não configurada');
console.log('[config] PORT:', PORT);
console.log('[config] Auth estático:', BEARER_TOKEN ? 'Bearer token configurado ✅' : '⚠️ sem token estático');
console.log('[config] OAuth:', OAUTH_ENABLED ? 'Google OAuth configurado ✅' : '⚠️ não configurado — apenas Bearer estático');

// ── Rate limiting (por credencial: token estático ou e-mail do JWT) ───────────
const RATE_LIMIT_MAX    = 60;     // máximo de requisições por janela
const RATE_LIMIT_WINDOW = 60000;  // janela de 1 minuto em ms
const rateLimitMap = new Map();

function checkRateLimit(key) {
  const now   = Date.now();
  const entry = rateLimitMap.get(key);
  if (!entry || now > entry.resetAt) {
    rateLimitMap.set(key, { count: 1, resetAt: now + RATE_LIMIT_WINDOW });
    return { allowed: true, remaining: RATE_LIMIT_MAX - 1 };
  }
  if (entry.count >= RATE_LIMIT_MAX) {
    return { allowed: false, remaining: 0, resetAt: entry.resetAt };
  }
  entry.count++;
  return { allowed: true, remaining: RATE_LIMIT_MAX - entry.count };
}

// Limpeza de entradas expiradas a cada 5 minutos
setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of rateLimitMap.entries()) {
    if (now > entry.resetAt) rateLimitMap.delete(key);
  }
}, 5 * 60 * 1000);

// ── OAuth state stores (em memória; trocar por Redis se houver múltiplas instâncias) ──
const oauthStates  = new Map(); // state → pedido /authorize pendente
const oauthCodes   = new Map(); // code  → autenticação concluída aguardando troca
const oauthClients = new Map(); // client_id → registro dinâmico

setInterval(() => {
  const now = Date.now();
  for (const [k, v] of oauthStates.entries()) if (now > v.expires) oauthStates.delete(k);
  for (const [k, v] of oauthCodes.entries())  if (now > v.expires) oauthCodes.delete(k);
}, 60 * 1000);

const pools = {};
function getPool(source) {
  const key = source === 'd0' ? 'd0' : 'd1';
  if (key === 'd0' && !D0_CFG) {
    throw new Error('Fonte d0 (produção) não configurada neste servidor');
  }
  if (!pools[key]) pools[key] = mysql2.createPool(key === 'd0' ? D0_CFG : MYSQL_CFG);
  return pools[key];
}

// ── Middleware ────────────────────────────────────────────────────────────────
app.use(express.json({ strict: false }));
app.use(express.urlencoded({ extended: false }));

app.use((req, _res, next) => {
  console.log('[req]', req.method, req.path);
  next();
});

// ── OAuth Discovery (RFC 9728 / RFC 8414) ─────────────────────────────────────
// O ChatGPT e outros clients MCP consultam estes endpoints (inclusive com o
// sufixo do path do servidor, ex.: /.well-known/oauth-protected-resource/mcp).
function protectedResourceMetadata(_req, res) {
  if (!OAUTH_ENABLED) return res.sendStatus(404);
  res.json({
    resource:              BASE_URL,
    authorization_servers: [BASE_URL],
    bearer_methods_supported: ['header'],
    scopes_supported:      ['mcp'],
  });
}

function authorizationServerMetadata(_req, res) {
  if (!OAUTH_ENABLED) return res.sendStatus(404);
  res.json({
    issuer:                                BASE_URL,
    authorization_endpoint:                BASE_URL + '/authorize',
    token_endpoint:                        BASE_URL + '/token',
    registration_endpoint:                 BASE_URL + '/register',
    response_types_supported:              ['code'],
    grant_types_supported:                 ['authorization_code'],
    code_challenge_methods_supported:      ['S256'],
    token_endpoint_auth_methods_supported: ['none'],
    scopes_supported:                      ['mcp'],
  });
}

app.get(['/.well-known/oauth-protected-resource',
         '/.well-known/oauth-protected-resource/mcp',
         '/.well-known/oauth-protected-resource/sse'], protectedResourceMetadata);

app.get(['/.well-known/oauth-authorization-server',
         '/.well-known/oauth-authorization-server/mcp',
         '/.well-known/oauth-authorization-server/sse',
         '/.well-known/openid-configuration'], authorizationServerMetadata);

// ── Dynamic Client Registration (RFC 7591) ────────────────────────────────────
app.post('/register', (req, res) => {
  if (!OAUTH_ENABLED) return res.sendStatus(404);
  const { redirect_uris, client_name } = req.body || {};
  if (!Array.isArray(redirect_uris) || redirect_uris.length === 0) {
    return res.status(400).json({ error: 'invalid_client_metadata', error_description: 'redirect_uris obrigatório' });
  }
  const clientId = crypto.randomUUID();
  oauthClients.set(clientId, { redirect_uris, client_name });
  console.log('[oauth] client registrado:', client_name, '|', clientId);
  res.status(201).json({
    client_id:                  clientId,
    redirect_uris,
    client_name,
    token_endpoint_auth_method: 'none',
    grant_types:                ['authorization_code'],
    response_types:             ['code'],
  });
});

// ── Authorization endpoint ────────────────────────────────────────────────────
app.get('/authorize', (req, res) => {
  if (!OAUTH_ENABLED) return res.sendStatus(404);
  const { client_id, redirect_uri, state, code_challenge, code_challenge_method } = req.query;
  if (!code_challenge || code_challenge_method !== 'S256') {
    return res.status(400).send('PKCE obrigatório (code_challenge S256 ausente)');
  }
  const client = oauthClients.get(client_id);
  if (client && Array.isArray(client.redirect_uris) && !client.redirect_uris.includes(redirect_uri)) {
    return res.status(400).send('redirect_uri não registrada para este client');
  }

  const authState = crypto.randomUUID();
  oauthStates.set(authState, {
    client_id, redirect_uri, state, code_challenge, code_challenge_method,
    expires: Date.now() + 10 * 60 * 1000,
  });

  const params = new URLSearchParams({
    response_type: 'code',
    client_id:     GOOGLE_CLIENT_ID,
    redirect_uri:  BASE_URL + '/callback',
    scope:         'openid email profile',
    state:         authState,
    access_type:   'online',
  });
  if (ALLOWED_EMAIL_DOMAIN) params.set('hd', ALLOWED_EMAIL_DOMAIN); // dica de domínio (a checagem real é feita no callback)
  res.redirect(`https://accounts.google.com/o/oauth2/v2/auth?${params}`);
});

// ── Google Callback ───────────────────────────────────────────────────────────
app.get('/callback', async (req, res) => {
  if (!OAUTH_ENABLED) return res.sendStatus(404);
  const { code, state: authState, error, error_description } = req.query;
  if (error) return res.status(400).send('Google error: ' + error + (error_description ? ' — ' + error_description : ''));

  const oauthReq = oauthStates.get(authState);
  if (!oauthReq || Date.now() > oauthReq.expires) {
    return res.status(400).send('Estado OAuth inválido ou expirado — tente conectar novamente');
  }
  oauthStates.delete(authState);

  try {
    const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
      method:  'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type:    'authorization_code',
        client_id:     GOOGLE_CLIENT_ID,
        client_secret: GOOGLE_CLIENT_SECRET,
        code,
        redirect_uri:  BASE_URL + '/callback',
      }),
    });
    const tokens = await tokenRes.json();
    if (tokens.error) throw new Error(tokens.error_description || tokens.error);

    const userRes = await fetch('https://openidconnect.googleapis.com/v1/userinfo', {
      headers: { 'Authorization': 'Bearer ' + tokens.access_token },
    });
    const user = await userRes.json();
    console.log('[oauth] autenticado:', user.email);

    if (ALLOWED_EMAIL_DOMAIN && !(user.email || '').endsWith('@' + ALLOWED_EMAIL_DOMAIN)) {
      console.warn('[oauth] domínio não autorizado:', user.email);
      return res.status(403).send('Domínio de e-mail não autorizado');
    }

    const mcpCode = crypto.randomUUID();
    oauthCodes.set(mcpCode, {
      ...oauthReq,
      email:   user.email,
      name:    user.name,
      expires: Date.now() + 5 * 60 * 1000,
    });

    const redirectParams = new URLSearchParams({ code: mcpCode });
    if (oauthReq.state != null) redirectParams.set('state', oauthReq.state);
    res.redirect(oauthReq.redirect_uri + (oauthReq.redirect_uri.includes('?') ? '&' : '?') + redirectParams);
  } catch (e) {
    console.error('[oauth] erro no callback:', e.message);
    res.status(500).send('Erro na autenticação: ' + e.message);
  }
});

// ── Token endpoint ────────────────────────────────────────────────────────────
app.post('/token', (req, res) => {
  if (!OAUTH_ENABLED) return res.sendStatus(404);
  const { grant_type, code, code_verifier } = req.body || {};
  if (grant_type !== 'authorization_code') {
    return res.status(400).json({ error: 'unsupported_grant_type' });
  }

  const codeData = oauthCodes.get(code);
  if (!codeData || Date.now() > codeData.expires) {
    return res.status(400).json({ error: 'invalid_grant', error_description: 'Código expirado ou inválido' });
  }
  oauthCodes.delete(code);

  if (!code_verifier) {
    return res.status(400).json({ error: 'invalid_request', error_description: 'code_verifier obrigatório (PKCE)' });
  }
  const challenge = crypto.createHash('sha256').update(code_verifier).digest('base64url');
  if (challenge !== codeData.code_challenge) {
    console.warn('[oauth] PKCE mismatch:', codeData.email);
    return res.status(400).json({ error: 'invalid_grant', error_description: 'PKCE inválido' });
  }

  const accessToken = jwt.sign(
    { sub: codeData.email, name: codeData.name, scope: 'mcp' },
    JWT_SECRET,
    { expiresIn: '8h', issuer: BASE_URL, audience: BASE_URL }
  );

  console.log('[oauth] token emitido para:', codeData.email);
  res.json({ access_token: accessToken, token_type: 'Bearer', expires_in: 8 * 3600, scope: 'mcp' });
});

// ── Bearer/JWT auth + rate limiting ──────────────────────────────────────────
function unauthorized(res) {
  res.setHeader('WWW-Authenticate',
    `Bearer resource_metadata="${BASE_URL}/.well-known/oauth-protected-resource"`);
  return res.status(401).json({ error: 'Unauthorized' });
}

function applyRateLimit(key, res) {
  const rl = checkRateLimit(key);
  res.setHeader('X-RateLimit-Limit',     RATE_LIMIT_MAX);
  res.setHeader('X-RateLimit-Remaining', rl.remaining);
  if (!rl.allowed) {
    const retryAfter = Math.ceil((rl.resetAt - Date.now()) / 1000);
    console.warn('[rate-limit] bloqueado | key:', key, '| retry-after:', retryAfter + 's');
    res.setHeader('Retry-After', retryAfter);
    res.status(429).json({ error: 'Too Many Requests', retryAfter });
    return false;
  }
  return true;
}

function requireAuth(req, res, next) {
  if (!BEARER_TOKEN && !OAUTH_ENABLED) return next(); // servidor aberto (dev)

  const authHeader = req.headers['authorization'] || '';
  let token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : null;
  if (!token && req.query && req.query.token) token = req.query.token; // legado
  if (!token) return unauthorized(res);

  // 1) Bearer estático (retrocompatibilidade — conector do Claude)
  if (BEARER_TOKEN && token === BEARER_TOKEN) {
    if (!applyRateLimit('static', res)) return;
    return next();
  }

  // 2) JWT emitido pelo fluxo OAuth
  if (OAUTH_ENABLED) {
    try {
      const decoded = jwt.verify(token, JWT_SECRET, { issuer: BASE_URL, audience: BASE_URL });
      req.user = decoded;
      if (!applyRateLimit(decoded.sub || 'jwt', res)) return;
      return next();
    } catch (e) {
      console.warn('[auth] JWT inválido:', e.message);
    }
  }

  console.warn('[auth] acesso negado:', req.method, req.path, '| ip:', req.ip);
  return unauthorized(res);
}

// ── Health (público) ──────────────────────────────────────────────────────────
app.get('/health', (_req, res) => res.json({ ok: true, db: MYSQL_CFG.database, d0: !!D0_CFG, oauth: OAUTH_ENABLED }));

// ── MCP Streamable HTTP Transport ─────────────────────────────────────────────
// /mcp  → endpoint canônico (Streamable HTTP, spec 2025-03-26+; exigido pelo ChatGPT Work)
// /sse  → alias legado mantido para retrocompatibilidade com conectores existentes
app.all(['/mcp', '/sse'], requireAuth, async (req, res) => {
  if (req.method === 'DELETE') {
    // Servidor stateless: encerramento de sessão é um no-op
    return res.sendStatus(200);
  }
  if (req.method === 'GET') {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders();
    const iv = setInterval(() => res.write(':ping\n\n'), 25000);
    req.on('close', () => clearInterval(iv));
    return;
  }

  const body     = req.body;
  const requests = Array.isArray(body) ? body : [body];
  const results  = [];

  for (const msg of requests) {
    try {
      const r = await handleMCP(msg, req.user);
      if (r !== null) results.push(r);
    } catch (e) {
      console.error('[mcp] unhandled error:', e.message);
      if (msg.id != null) results.push(jsonrpcErr(msg.id, -32603, e.message));
    }
  }

  if (results.length === 0) return res.sendStatus(202);
  res.setHeader('Content-Type', 'application/json');
  res.json(results.length === 1 ? results[0] : results);
});

// ── MCP JSON-RPC handler ──────────────────────────────────────────────────────
async function handleMCP(msg, user) {
  const { method, params, id } = msg || {};
  console.log('[mcp] method:', method, '| id:', id, user ? '| user: ' + user.sub : '');

  function ok(result) { return id != null ? { jsonrpc: '2.0', id, result } : null; }

  switch (method) {

    case 'initialize':
      return ok({
        protocolVersion: (params && params.protocolVersion) || '2024-11-05',
        capabilities:    { tools: { listChanged: false } },
        serverInfo:      { name: 'boobam-mysql', version: '2.1.0' },
      });

    case 'initialized':
    case 'notifications/initialized':
      return null;

    case 'ping':
      return ok({});

    case 'tools/list': {
      const sourceProp = {
        type: 'string',
        enum: ['d1', 'd0'],
        description: 'Fonte de dados: "d1" = réplica D-1 de QA (padrão, dados de ontem); "d0" = Aurora de produção em tempo real, endpoint reader somente leitura. Use "d0" apenas quando precisar de dados do dia.',
      };
      return ok({
        tools: [
          {
            name: 'list_tables',
            description: 'Lista todas as tabelas do banco de dados Boobam. Aceita source "d1" (réplica D-1, padrão) ou "d0" (produção em tempo real, somente leitura).',
            inputSchema: { type: 'object', properties: { source: sourceProp }, required: [] },
            annotations: { title: 'Listar tabelas', readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
          },
          {
            name: 'describe_table',
            description: 'Descreve a estrutura (colunas, tipos) de uma tabela. Aceita source "d1" (réplica D-1, padrão) ou "d0" (produção em tempo real, somente leitura).',
            inputSchema: {
              type: 'object',
              properties: { table: { type: 'string', description: 'Nome da tabela' }, source: sourceProp },
              required: ['table'],
            },
            annotations: { title: 'Descrever tabela', readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
          },
          {
            name: 'query',
            description: 'Executa uma query SQL SELECT no banco Boobam. Apenas leitura. Aceita source "d1" (réplica D-1, padrão) ou "d0" (produção em tempo real, somente leitura — use para dados do dia).',
            inputSchema: {
              type: 'object',
              properties: { sql: { type: 'string', description: 'Query SQL SELECT' }, source: sourceProp },
              required: ['sql'],
            },
            annotations: { title: 'Query SELECT (somente leitura)', readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
          },
        ],
      });
    }

    case 'tools/call': {
      const name   = params && params.name;
      const args   = (params && params.arguments) || {};
      const source = args.source === 'd0' ? 'd0' : 'd1';
      console.log('[tool] calling:', name, '| source:', source, args, user ? '| user: ' + user.sub : '');
      let db;
      try {
        db = getPool(source);
      } catch (cfgErr) {
        return ok({ content: [{ type: 'text', text: 'Erro: ' + cfgErr.message }], isError: true });
      }
      try {
        let text = '';
        if (name === 'list_tables') {
          const [rows] = await db.query('SHOW TABLES');
          text = rows.map(r => Object.values(r)[0]).join('\n');
        } else if (name === 'describe_table') {
          const tbl = String(args.table || '').replace(/[^a-zA-Z0-9_]/g, '');
          if (!tbl) throw new Error('Nome de tabela inválido');
          const [rows] = await db.query('DESCRIBE `' + tbl + '`');
          text = JSON.stringify(rows, null, 2);
        } else if (name === 'query') {
          const sql = String(args.sql || '').trim();
          if (!/^SELECT\b/i.test(sql)) throw new Error('Apenas queries SELECT são permitidas');
          const [rows] = await db.query(sql);
          text = (Array.isArray(rows) && rows.length === 0)
            ? '(nenhum resultado)'
            : JSON.stringify(rows, null, 2);
        } else {
          throw new Error('Tool desconhecida: ' + name);
        }
        return ok({ content: [{ type: 'text', text }] });
      } catch (toolErr) {
        console.error('[tool error]', toolErr.message);
        return ok({ content: [{ type: 'text', text: 'Erro: ' + toolErr.message }], isError: true });
      }
    }

    default:
      console.warn('[mcp] unknown method:', method);
      if (id != null) return jsonrpcErr(id, -32601, 'Method not found: ' + method);
      return null;
  }
}

function jsonrpcErr(id, code, message) {
  return { jsonrpc: '2.0', id, error: { code, message } };
}

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log('✅ Boobam MCP server v2.1.0 listening on 0.0.0.0:' + PORT);
  console.log('[rate-limit] ' + RATE_LIMIT_MAX + ' req/min por credencial');
});

process.on('unhandledRejection', (reason) => { console.error('[unhandledRejection]', reason); });
process.on('uncaughtException',  (err)    => { console.error('[uncaughtException]',  err);    });
