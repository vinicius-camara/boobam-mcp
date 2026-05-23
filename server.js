import express from 'express';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { SSEServerTransport } from '@modelcontextprotocol/sdk/server/sse.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import mysql from 'mysql2/promise';

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;
const MYSQL_HOST = process.env.MYSQL_HOST || '127.0.0.1';
const MYSQL_PORT = parseInt(process.env.MYSQL_PORT || '3307');
const MYSQL_USER = process.env.MYSQL_USER || 'root';
const MYSQL_PASS = process.env.MYSQL_PASS || '';
const MYSQL_DB   = process.env.MYSQL_DB   || 'boobam';

console.log(`[config] MySQL: ${MYSQL_USER}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}`);

// MySQL connection pool (lazy)
let pool = null;
function getPool() {
  if (!pool) {
    pool = mysql.createPool({
      host: MYSQL_HOST,
      port: MYSQL_PORT,
      user: MYSQL_USER,
      password: MYSQL_PASS,
      database: MYSQL_DB,
      waitForConnections: true,
      connectionLimit: 5,
      connectTimeout: 10000,
    });
  }
  return pool;
}

// ── OAuth discovery endpoints (claude.ai probes these) ───────────────────────
// Returning 404 tells claude.ai that no OAuth is required — proceed anonymously
app.get('/.well-known/oauth-protected-resource', (_req, res) => res.sendStatus(404));
app.get('/.well-known/oauth-authorization-server', (_req, res) => res.sendStatus(404));
app.post('/register', (_req, res) => res.sendStatus(404));

// ── Health ───────────────────────────────────────────────────────────────────
app.get('/health', (_req, res) => res.json({ status: 'ok', db: MYSQL_DB }));

// ── MCP SSE transport ────────────────────────────────────────────────────────
// Map sessionId → SSEServerTransport (for POST /message routing)
const transports = {};

app.get('/sse', async (_req, res) => {
  console.log('[sse] nova conexão');

  const server = new Server(
    { name: 'boobam-mysql', version: '1.0.0' },
    { capabilities: { tools: {} } }
  );

  // Tool: list_tables
  // Tool: describe_table
  // Tool: query (SELECT only)
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: 'list_tables',
        description: 'Lista todas as tabelas do banco Boobam.',
        inputSchema: { type: 'object', properties: {} },
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
        description: 'Executa uma query SQL de leitura (SELECT) no banco Boobam.',
        inputSchema: {
          type: 'object',
          properties: {
            sql: { type: 'string', description: 'Query SQL SELECT' },
          },
          required: ['sql'],
        },
      },
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    console.log(`[tool] ${name}`, args);
    const db = getPool();

    try {
      if (name === 'list_tables') {
        const [rows] = await db.query('SHOW TABLES');
        const tables = rows.map(r => Object.values(r)[0]);
        return { content: [{ type: 'text', text: tables.join('\n') }] };
      }

      if (name === 'describe_table') {
        const tbl = (args.table || '').replace(/[^a-zA-Z0-9_]/g, '');
        if (!tbl) return { content: [{ type: 'text', text: 'Nome de tabela inválido.' }], isError: true };
        const [rows] = await db.query(`DESCRIBE \`${tbl}\``);
        return { content: [{ type: 'text', text: JSON.stringify(rows, null, 2) }] };
      }

      if (name === 'query') {
        const sql = (args.sql || '').trim();
        if (!/^SELECT\b/i.test(sql)) {
          return {
            content: [{ type: 'text', text: 'Apenas queries SELECT são permitidas por segurança.' }],
            isError: true,
          };
        }
        const [rows] = await db.query(sql);
        const text = Array.isArray(rows) && rows.length === 0
          ? '(nenhum resultado)'
          : JSON.stringify(rows, null, 2);
        return { content: [{ type: 'text', text }] };
      }

      return { content: [{ type: 'text', text: `Ferramenta desconhecida: ${name}` }], isError: true };
    } catch (err) {
      console.error(`[tool error] ${name}:`, err.message);
      return { content: [{ type: 'text', text: `Erro: ${err.message}` }], isError: true };
    }
  });

  const transport = new SSEServerTransport('/message', res);
  transports[transport.sessionId] = transport;

  res.on('close', () => {
    console.log(`[sse] conexão encerrada: ${transport.sessionId}`);
    delete transports[transport.sessionId];
  });

  await server.connect(transport);
});

app.post('/message', async (req, res) => {
  const sessionId = req.query.sessionId;
  const transport = transports[sessionId];
  if (!transport) {
    console.warn(`[message] sessão não encontrada: ${sessionId}`);
    return res.status(404).json({ error: 'Session not found' });
  }
  await transport.handlePostMessage(req, res);
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`✅ Boobam MCP server escutando em 0.0.0.0:${PORT}`);
  console.log(`   SSE endpoint: http://0.0.0.0:${PORT}/sse`);
});
