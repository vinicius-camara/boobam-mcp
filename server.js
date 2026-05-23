'use strict';

const express = require('express');
const mysql2  = require('mysql2/promise');

const app  = express();
const PORT = parseInt(process.env.PORT || '3000', 10);

const MYSQL_CFG = {
  host:            process.env.MYSQL_HOST || '127.0.0.1',
  port:            parseInt(process.env.MYSQL_PORT || '3307', 10),
  user:            process.env.MYSQL_USER || 'root',
  password:        process.env.MYSQL_PASS || '',
  database:        process.env.MYSQL_DB   || 'boobam',
  waitForConnections: true,
  connectionLimit: 5,
  connectTimeout:  10000,
};

const BEARER_TOKEN = process.env.BEARER_TOKEN || '';

console.log('[config] MySQL:', MYSQL_CFG.user + '@' + MYSQL_CFG.host + ':' + MYSQL_CFG.port + '/' + MYSQL_CFG.database);
console.log('[config] PORT:', PORT);
console.log('[config] Auth:', BEARER_TOKEN ? 'Bearer token configured ✅' : '⚠️  NO TOKEN SET — server is open!');

let pool = null;
function getPool() {
  if (!pool) pool = mysql2.createPool(MYSQL_CFG);
  return pool;
}

// ── Middleware ────────────────────────────────────────────────────────────────
app.use(express.json({ strict: false }));

app.use((req, _res, next) => {
  console.log('[req]', req.method, req.path);
  next();
});

// ── OAuth discovery: 404 = no auth required ───────────────────────────────────
// Estes endpoints ficam públicos para o claude.ai checar antes de autenticar
app.get('/.well-known/oauth-protected-resource',         (_req, res) => res.sendStatus(404));
app.get('/.well-known/oauth-protected-resource/sse',     (_req, res) => res.sendStatus(404));
app.get('/.well-known/oauth-authorization-server',       (_req, res) => res.sendStatus(404));
app.get('/.well-known/oauth-authorization-server/sse',   (_req, res) => res.sendStatus(404));
app.post('/register',                                    (_req, res) => res.sendStatus(404));

// ── Bearer token auth middleware ──────────────────────────────────────────────
// Aceita token via header Authorization: Bearer TOKEN
// ou via query param ?token=TOKEN (útil para configurar URL no claude.ai)
function requireAuth(req, res, next) {
  if (!BEARER_TOKEN) return next(); // sem token configurado: aceita tudo (modo dev)

  // Verifica header
  const authHeader = req.headers['authorization'] || '';
  if (authHeader.startsWith('Bearer ') && authHeader.slice(7) === BEARER_TOKEN) {
    return next();
  }

  // Verifica query param
  if (req.query && req.query.token === BEARER_TOKEN) {
    return next();
  }

  console.warn('[auth] acesso negado:', req.method, req.path, '| ip:', req.ip);
  return res.status(401).json({ error: 'Unauthorized' });
}

// ── Health (público — só verifica se o servidor está de pé) ───────────────────
app.get('/health', (_req, res) => res.json({ ok: true, db: MYSQL_CFG.database }));

// ── MCP Streamable HTTP Transport (POST) + legacy SSE GET ────────────────────
app.all('/sse', requireAuth, async (req, res) => {
  if (req.method === 'GET') {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders();
    const iv = setInterval(() => res.write(':ping\n\n'), 25000);
    req.on('close', () => clearInterval(iv));
    return;
  }

  // POST — Streamable HTTP Transport
  let body = req.body;
  const requests = Array.isArray(body) ? body : [body];
  const results  = [];

  for (const msg of requests) {
    try {
      const r = await handleMCP(msg);
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
async function handleMCP(msg) {
  const { method, params, id } = msg || {};
  console.log('[mcp] method:', method, '| id:', id);

  function ok(result) { return id != null ? { jsonrpc: '2.0', id, result } : null; }

  switch (method) {

    case 'initialize':
      return ok({
        protocolVersion: (params && params.protocolVersion) || '2024-11-05',
        capabilities:    { tools: { listChanged: false } },
        serverInfo:      { name: 'boobam-mysql', version: '1.0.0' },
      });

    case 'initialized':
    case 'notifications/initialized':
      return null;

    case 'ping':
      return ok({});

    case 'tools/list':
      return ok({
        tools: [
          {
            name: 'list_tables',
            description: 'Lista todas as tabelas do banco de dados Boobam.',
            inputSchema: { type: 'object', properties: {}, required: [] },
          },
          {
            name: 'describe_table',
            description: 'Descreve a estrutura (colunas, tipos) de uma tabela.',
            inputSchema: {
              type: 'object',
              properties: {
                table: { type: 'string', description: 'Nome da tabela' },
              },
              required: ['table'],
            },
          },
          {
            name: 'query',
            description: 'Executa uma query SQL SELECT no banco Boobam. Apenas leitura.',
            inputSchema: {
              type: 'object',
              properties: {
                sql: { type: 'string', description: 'Query SQL SELECT' },
              },
              required: ['sql'],
            },
          },
        ],
      });

    case 'tools/call': {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      const db   = getPool();
      console.log('[tool] calling:', name, args);
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
  console.log('✅ Boobam MCP server listening on 0.0.0.0:' + PORT);
});

process.on('unhandledRejection', (reason) => { console.error('[unhandledRejection]', reason); });
process.on('uncaughtException',  (err)    => { console.error('[uncaughtException]', err); });
