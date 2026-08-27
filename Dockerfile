# syntax=docker/dockerfile:1.4
FROM node:20-alpine AS builder

# Install system build dependencies for SQLite3 native compilation
RUN apk add --no-cache python3 make g++ gcc sqlite git

WORKDIR /app

# Step 1: Inject Package Manifest
RUN cat << 'EOF' > package.json
{
  "name": "enterprise-mineflayer-cluster",
  "version": "2.5.0",
  "description": "Multi-Tenant Minecraft Bot Engine & Dashboard",
  "main": "bot.js",
  "scripts": {
    "start": "node bot.js"
  },
  "dependencies": {
    "@groq/groq-sdk": "^0.5.0",
    "axios": "^1.6.8",
    "bcryptjs": "^2.4.3",
    "connect-sqlite3": "^0.9.15",
    "cors": "^2.8.5",
    "dotenv": "^16.4.0",
    "express": "^4.19.0",
    "express-rate-limit": "^7.2.0",
    "express-session": "^1.18.0",
    "helmet": "^7.1.0",
    "mineflayer": "^4.20.0",
    "mineflayer-armor-manager": "^2.0.1",
    "mineflayer-auto-eat": "^1.4.0",
    "mineflayer-collectblock": "^1.6.0",
    "mineflayer-pathfinder": "^2.4.0",
    "mineflayer-pvp": "^1.3.0",
    "socket.io": "^4.7.0",
    "socks-proxy-agent": "^8.0.3",
    "sqlite3": "^5.1.7",
    "vec3": "^0.1.10"
  }
}
EOF

# Install Node dependencies
RUN npm install --production

# Step 2: Inject Complete Application Code (bot.js)
RUN cat << 'EOF' > bot.js
'use me strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const { execSync } = require('child_process');

// Dynamic Auto-Bootstrapper & Dependency Auto-Installer
const REQUIRED_MODULES = [
  'express', 'socket.io', 'dotenv', 'helmet', 'cors', 'mineflayer',
  'mineflayer-pathfinder', 'mineflayer-auto-eat', 'mineflayer-armor-manager',
  'mineflayer-collectblock', 'mineflayer-pvp', 'vec3', '@groq/groq-sdk',
  'bcryptjs', 'express-session', 'connect-sqlite3', 'express-rate-limit',
  'sqlite3', 'socks-proxy-agent', 'axios'
];

(function autoInstallDependencies() {
  const missing = [];
  for (const mod of REQUIRED_MODULES) {
    try {
      require(mod);
    } catch (e) {
      missing.push(mod);
    }
  }
  if (missing.length > 0) {
    console.log(`[BOOTSTRAP] Missing dependencies detected: ${missing.join(', ')}. Auto-installing...`);
    try {
      execSync(`npm install --production ${missing.join(' ')}`, { stdio: 'inherit' });
      console.log('[BOOTSTRAP] Dependencies successfully installed.');
    } catch (err) {
      console.error('[BOOTSTRAP CRITICAL] Dependency auto-installer failed:', err);
    }
  }
})();

// Imports
require('dotenv').config();
const express = require('express');
const { Server } = require('socket.io');
const helmet = require('helmet');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const session = require('express-session');
const SQLiteStore = require('connect-sqlite3')(session);
const rateLimit = require('express-rate-limit');
const sqlite3 = require('sqlite3').verbose();
const { SocksProxyAgent } = require('socks-proxy-agent');
const axios = require('axios');
const Groq = require('@groq/groq-sdk');
const mineflayer = require('mineflayer');
const pathfinder = require('mineflayer-pathfinder').pathfinder;
const { Movements, goals } = require('mineflayer-pathfinder');
const autoEat = require('mineflayer-auto-eat').plugin;
const armorManager = require('mineflayer-armor-manager');
const collectBlock = require('mineflayer-collectblock').plugin;
const pvp = require('mineflayer-pvp').plugin;
const vec3 = require('vec3');

// Configurations & Environment
const PORT = process.env.PORT || 3000;
const SESSION_SECRET = process.env.SESSION_SECRET || 'super-secret-cluster-key-9988';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'AdminPass123!';
const GROQ_API_KEY = process.env.GROQ_API_KEY || '';

// Initialize SQLite Database with WAL Mode
const DATA_DIR = path.join(__dirname, 'data');
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}
const DB_PATH = path.join(DATA_DIR, 'system.db');
const db = new sqlite3.Database(DB_PATH);

db.serialize(() => {
  db.run('PRAGMA journal_mode = WAL;');
  db.run('PRAGMA synchronous = NORMAL;');

  db.run(`CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'subscriber',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )`);

  db.run(`CREATE TABLE IF NOT EXISTS bots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id INTEGER NOT NULL,
    username TEXT NOT NULL,
    host TEXT NOT NULL,
    port INTEGER NOT NULL DEFAULT 25565,
    version TEXT DEFAULT 'auto',
    auth_mode TEXT DEFAULT 'offline',
    proxy TEXT DEFAULT '',
    auto_auth_pass TEXT DEFAULT '',
    webhook_url TEXT DEFAULT '',
    is_active INTEGER DEFAULT 0,
    FOREIGN KEY(owner_id) REFERENCES users(id)
  )`);

  db.run(`CREATE TABLE IF NOT EXISTS proxies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    proxy_str TEXT UNIQUE NOT NULL,
    status TEXT DEFAULT 'UNKNOWN',
    latency INTEGER DEFAULT 0
  )`);

  db.run(`CREATE TABLE IF NOT EXISTS macros (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    dsl_code TEXT NOT NULL
  )`);

  // Seed Admin Account
  db.get('SELECT * FROM users WHERE role = ?', ['admin'], (err, row) => {
    if (!row) {
      const hash = bcrypt.hashSync(ADMIN_PASSWORD, 12);
      db.run('INSERT INTO users (username, password, role) VALUES (?, ?, ?)', ['admin', hash, 'admin'], (e) => {
        if (!e) console.log('[DB] Default Admin account created. Username: admin');
      });
    }
  });
});

// Express App Architecture & Middleware Setup
const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  pingInterval: 20000,
  pingTimeout: 45000,
  cors: { origin: '*', methods: ['GET', 'POST'] }
});

app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

const sessionMiddleware = session({
  store: new SQLiteStore({ db: 'system.db', dir: DATA_DIR }),
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 7 * 24 * 60 * 60 * 1000, secure: false }
});

app.use(sessionMiddleware);
io.engine.use(sessionMiddleware);

// Rate Limiters
const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 5, message: { error: 'Too many auth attempts' } });
const apiLimiter = rateLimit({ windowMs: 1 * 60 * 1000, max: 40 });
app.use('/api/auth/', authLimiter);
app.use('/api/', apiLimiter);

// Authentication & Auth RBAC Middlewares
function requireAuth(req, res, next) {
  if (req.session && req.session.user) return next();
  return res.status(401).json({ error: 'Unauthorized' });
}
function requireAdmin(req, res, next) {
  if (req.session && req.session.user && req.session.user.role === 'admin') return next();
  return res.status(403).json({ error: 'Forbidden: Admin access required' });
}

// REST Endpoints
app.post('/api/auth/login', (req, res) => {
  const { username, password } = req.body;
  db.get('SELECT * FROM users WHERE username = ?', [username], (err, user) => {
    if (err || !user) return res.status(401).json({ error: 'Invalid credentials' });
    if (!bcrypt.compareSync(password, user.password)) return res.status(401).json({ error: 'Invalid credentials' });
    req.session.user = { id: user.id, username: user.username, role: user.role };
    return res.json({ success: true, user: req.session.user });
  });
});

app.post('/api/auth/logout', (req, res) => {
  req.session.destroy();
  res.json({ success: true });
});

app.get('/api/auth/me', (req, res) => {
  if (req.session && req.session.user) return res.json({ user: req.session.user });
  res.status(401).json({ error: 'Unauthenticated' });
});

// Mineflayer Active Cluster Manager Map
const clusterManager = new Map(); // Key: Bot DB ID -> Bot Managed Instance

// Groq AI Integration
const groq = GROQ_API_KEY ? new Groq({ apiKey: GROQ_API_KEY }) : null;
const aiContexts = new Map(); // Key: username -> context array

async function queryGroqAI(prompt, userContextKey = 'global') {
  if (!groq) return 'Groq AI Service not configured (Missing GROQ_API_KEY).';
  try {
    let history = aiContexts.get(userContextKey) || [];
    history.push({ role: 'user', content: prompt });
    if (history.length > 10) history = history.slice(history.length - 10);
    
    const response = await groq.chat.completions.create({
      messages: [
        { role: 'system', content: 'You are Finny, an elite Minecraft AFK Cluster AI Engine. Keep response under 250 chars for in-game chat.' },
        ...history
      ],
      model: 'llama-3.3-70b-versatile',
      temperature: 0.7,
      max_tokens: 150
    });
    const reply = response.choices[0]?.message?.content || 'AI response generation empty.';
    history.push({ role: 'assistant', content: reply });
    aiContexts.set(userContextKey, history);
    return reply;
  } catch (err) {
    return `AI Error: ${err.message}`;
  }
}

// Discord Webhook Dispatcher
async function sendDiscordWebhook(url, title, description, color = 0x00FF00) {
  if (!url || !url.startsWith('http')) return;
  try {
    await axios.post(url, {
      embeds: [{ title, description, color: color, timestamp: new Date().toISOString() }]
    });
  } catch (e) {
    console.error('[WEBHOOK ERROR]', e.message);
  }
}

// Bot Class & Lifecycle Engine
class ClusterBotInstance {
  constructor(config) {
    this.config = config; // DB row data
    this.bot = null;
    this.reconnectAttempts = 0;
    this.reconnectTimer = null;
    this.antiAfkInterval = null;
    this.telemetryInterval = null;
    this.logs = [];
    this.status = 'DISCONNECTED';
    this.radarData = [];
  }

  log(category, message) {
    const entry = { timestamp: new Date().toLocaleTimeString(), category, message };
    this.logs.push(entry);
    if (this.logs.length > 1500) this.logs.shift();
    io.emit('bot_log', { botId: this.config.id, log: entry });
  }

  spawn() {
    this.status = 'AUTHENTICATING';
    this.log('System', `Initiating cluster spawn sequence to ${this.config.host}:${this.config.port}...`);
    
    const options = {
      host: this.config.host,
      port: parseInt(this.config.port),
      username: this.config.username,
      version: this.config.version === 'auto' ? false : this.config.version,
      auth: this.config.auth_mode === 'microsoft' ? 'microsoft' : 'offline'
    };

    if (this.config.proxy) {
      options.agent = new SocksProxyAgent(this.config.proxy);
    }

    try {
      this.bot = mineflayer.createBot(options);
    } catch (err) {
      this.log('Bot Error', `Spawn Exception: ${err.message}`);
      this.scheduleReconnection();
      return;
    }

    // Attach Mineflayer Plugins
    this.bot.loadPlugin(pathfinder);
    this.bot.loadPlugin(autoEat);
    this.bot.loadPlugin(armorManager);
    this.bot.loadPlugin(collectBlock);
    this.bot.loadPlugin(pvp);

    // Event Registration
    this.bot.once('spawn', () => {
      this.status = 'CONNECTED';
      this.reconnectAttempts = 0;
      this.log('System', `Successfully spawned and joined target world!`);
      
      // Auto Armor & Auto Eat Setup
      this.bot.armorManager.enable();
      this.bot.autoEat.options = {
        priority: 'foodPoints',
        startAt: 14,
        bannedFood: ['rotten_flesh', 'poisonous_potato', 'pufferfish', 'spider_eye']
      };

      this.startAntiAfkEngine();
      this.startTelemetryPump();
      db.run('UPDATE bots SET is_active = 1 WHERE id = ?', [this.config.id]);
    });

    this.bot.on('chat', (username, message) => {
      if (username === this.bot.username) return;
      this.log('Chat', `<${username}> ${message}`);
      this.handleAutoAuth(message);
      this.handleAIChatHook(username, message);
    });

    this.bot.on('whisper', (username, message) => {
      this.log('Chat', `[Whisper] <${username}> ${message}`);
      sendDiscordWebhook(this.config.webhook_url, 'Whisper Received', `From ${username}: ${message}`, 0x9B59B6);
      this.handleAIWhisperHook(username, message);
    });

    this.bot.on('health', () => {
      if (this.bot.health <= 6) {
        this.log('Bot Errors', `CRITICAL HEALTH WARNING: ${this.bot.health}/20`);
        sendDiscordWebhook(this.config.webhook_url, 'Health Emergency', `Health dropped to ${this.bot.health}`, 0xE74C3C);
      }
    });

    this.bot.on('kicked', (reason) => {
      const parsed = typeof reason === 'string' ? reason : JSON.stringify(reason);
      this.log('Bot Errors', `Kicked from server: ${parsed}`);
      sendDiscordWebhook(this.config.webhook_url, 'Bot Kicked', `Reason: ${parsed}`, 0xE67E22);
    });

    this.bot.on('error', (err) => {
      this.log('Bot Errors', `Mineflayer Error: ${err.message}`);
    });

    this.bot.on('end', (reason) => {
      this.status = 'DISCONNECTED';
      this.log('System', `Connection lost: ${reason}`);
      this.cleanup();
      this.scheduleReconnection();
    });
  }

  // Jittered Exponential Backoff Reconnection Formula
  scheduleReconnection() {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectAttempts++;
    const tInitial = 3000;
    const tMax = 180000;
    const jitter = Math.floor(Math.random() * 2000);
    const delay = Math.min(tMax, tInitial * Math.pow(2, this.reconnectAttempts) + jitter);
    
    this.status = 'RECONNECTING';
    this.log('System', `Backoff reconnection attempt #${this.reconnectAttempts} scheduled in ${Math.round(delay/1000)} seconds.`);
    this.reconnectTimer = setTimeout(() => {
      this.spawn();
    }, delay);
  }

  // Humanized Anti-AFK Engine
  startAntiAfkEngine() {
    if (this.antiAfkInterval) clearInterval(this.antiAfkInterval);
    this.antiAfkInterval = setInterval(() => {
      if (!this.bot || this.status !== 'CONNECTED') return;
      
      const randomAction = Math.floor(Math.random() * 5);
      const yaw = Math.random() * Math.PI * 2;
      const pitch = (Math.random() - 0.5) * Math.PI * 0.5;

      this.bot.look(yaw, pitch, true);

      switch (randomAction) {
        case 0:
          this.bot.setControlState('sneak', true);
          setTimeout(() => this.bot.setControlState('sneak', false), 800 + Math.random() * 1000);
          break;
        case 1:
          this.bot.setControlState('jump', true);
          setTimeout(() => this.bot.setControlState('jump', false), 250);
          break;
        case 2:
          this.bot.setControlState('forward', true);
          setTimeout(() => this.bot.setControlState('forward', false), 400);
          break;
        case 3:
          const currentSlot = this.bot.quickBarSlot;
          this.bot.setQuickBarSlot((currentSlot + 1) % 9);
          break;
        default:
          break;
      }
    }, (120 + Math.floor(Math.random() * 180)) * 1000); // 2 to 5 minutes randomized
  }

  // Auto-Auth Regex Interceptor
  handleAutoAuth(message) {
    if (!this.config.auto_auth_pass) return;
    const authRegex = /(?:\/register|\/login|Please log in|Type \/auth)/i;
    if (authRegex.test(message)) {
      const delay = 800 + Math.floor(Math.random() * 1400); // 800ms - 2200ms
      setTimeout(() => {
        if (message.includes('/register')) {
          this.bot.chat(`/register ${this.config.auto_auth_pass} ${this.config.auto_auth_pass}`);
        } else {
          this.bot.chat(`/login ${this.config.auto_auth_pass}`);
        }
        this.log('System', 'Auto-Auth credential sequence executed.');
      }, delay);
    }
  }

  // In-Game AI Chat Hooks
  async handleAIChatHook(username, message) {
    if (message.startsWith('!ai ')) {
      const prompt = message.replace('!ai ', '').trim();
      const reply = await queryGroqAI(prompt, username);
      this.bot.chat(reply);
      this.log('AI', `Public AI trigger by ${username}: ${reply}`);
    }
  }

  async handleAIWhisperHook(username, message) {
    if (message.startsWith('!ai ') || message.length > 3) {
      const reply = await queryGroqAI(message.replace('!ai ', ''), username);
      this.bot.chat(`/w ${username} ${reply}`);
      this.log('AI', `Whisper AI response sent to ${username}`);
    }
  }

  // Spatial Radar & Inventory Telemetry Pump
  startTelemetryPump() {
    if (this.telemetryInterval) clearInterval(this.telemetryInterval);
    this.telemetryInterval = setInterval(() => {
      if (!this.bot || !this.bot.entity) return;

      // Extract Nearby Entities within 32 blocks for 2D Radar
      const entities = [];
      for (const id in this.bot.entities) {
        const entity = this.bot.entities[id];
        if (entity === this.bot.entity) continue;
        const dist = this.bot.entity.position.distanceTo(entity.position);
        if (dist <= 32) {
          entities.push({
            id: entity.id,
            name: entity.name || entity.username || entity.type,
            type: entity.type,
            x: Math.round(entity.position.x - this.bot.entity.position.x),
            z: Math.round(entity.position.z - this.bot.entity.position.z)
          });
        }
      }

      // 9x4 Inventory Map
      const inventory = this.bot.inventory.slots.slice(0, 36).map((item, idx) => ({
        slot: idx,
        name: item ? item.name : 'empty',
        count: item ? item.count : 0
      }));

      const telemetry = {
        botId: this.config.id,
        health: this.bot.health || 0,
        food: this.bot.food || 0,
        ping: this.bot.player ? this.bot.player.ping : 0,
        pos: {
          x: Math.round(this.bot.entity.position.x),
          y: Math.round(this.bot.entity.position.y),
          z: Math.round(this.bot.entity.position.z)
        },
        dimension: this.bot.game ? this.bot.game.dimension : 'overworld',
        entities,
        inventory,
        yaw: this.bot.entity.yaw
      };

      io.emit('bot_telemetry', telemetry);
    }, 1000);
  }

  // Clean Destruction & Memory Safeguard Purge
  cleanup() {
    if (this.antiAfkInterval) clearInterval(this.antiAfkInterval);
    if (this.telemetryInterval) clearInterval(this.telemetryInterval);
    if (this.bot) {
      this.bot.removeAllListeners();
      if (this.bot.pathfinder) this.bot.pathfinder.setGoal(null);
      try { this.bot.end(); } catch (e) {}
      this.bot = null;
    }
  }

  destroy() {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.cleanup();
    db.run('UPDATE bots SET is_active = 0 WHERE id = ?', [this.config.id]);
    this.status = 'DISCONNECTED';
    this.log('System', 'Bot instance completely terminated.');
  }
}

// Global Memory Leak & V8 Heap Safeguard Monitor
setInterval(() => {
  const memoryUsage = process.memoryUsage();
  const heapUsedMB = Math.round(memoryUsage.heapUsed / 1024 / 1024);
  const heapTotalMB = Math.round(memoryUsage.heapTotal / 1024 / 1024);
  const ratio = memoryUsage.heapUsed / memoryUsage.heapTotal;

  if (ratio > 0.85) {
    console.warn(`[V8 HEAP CRITICAL] High memory consumption detected: ${heapUsedMB}MB / ${heapTotalMB}MB (${Math.round(ratio*100)}%). Triggering Force GC...`);
    if (global.gc) global.gc();
  }
}, 30000);

// Macro Interpreter Engine
async function executeMacroDSL(botInst, dslCode) {
  const lines = dslCode.split('\n');
  for (let line of lines) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    const tokens = line.split(' ');
    const cmd = tokens[0].toUpperCase();

    if (!botInst || !botInst.bot) break;

    switch (cmd) {
      case 'DELAY':
        await new Promise(r => setTimeout(r, parseInt(tokens[1]) || 1000));
        break;
      case 'SAY':
        botInst.bot.chat(tokens.slice(1).join(' '));
        break;
      case 'COMMAND':
        botInst.bot.chat('/' + tokens.slice(1).join(' '));
        break;
      case 'MOVE':
        const dir = tokens[1];
        const dur = parseInt(tokens[2]) || 1000;
        botInst.bot.setControlState(dir, true);
        await new Promise(r => setTimeout(r, dur));
        botInst.bot.setControlState(dir, false);
        break;
      case 'LOOK':
        botInst.bot.look(parseFloat(tokens[1]), parseFloat(tokens[2]), true);
        break;
      case 'EQUIP':
        const slot = parseInt(tokens[1]);
        botInst.bot.setQuickBarSlot(slot);
        break;
      case 'DROP_ALL':
        for (const item of botInst.bot.inventory.items()) {
          await botInst.bot.tossStack(item);
        }
        break;
      default:
        botInst.log('Macro Error', `Unknown DSL Directive: ${cmd}`);
    }
  }
}

// Dynamic Auto-Recovery: Respawn previously active bots on boot
db.all('SELECT * FROM bots WHERE is_active = 1', [], (err, rows) => {
  if (err || !rows) return;
  console.log(`[AUTO-RECOVERY] Resuming ${rows.length} bots from persistent database state...`);
  rows.forEach(botConfig => {
    const inst = new ClusterBotInstance(botConfig);
    clusterManager.set(botConfig.id, inst);
    inst.spawn();
  });
});

// Real-Time Socket.io Terminal & Control Handlers
io.on('connection', (socket) => {
  socket.on('register_terminal_command', async (data) => {
    const { botId, commandStr } = data;
    const instance = clusterManager.get(botId);
    if (!instance && !commandStr.startsWith('/add') && !commandStr.startsWith('/stopall')) {
      return socket.emit('terminal_response', { status: 'error', message: 'Bot instance active reference not found.' });
    }

    const parts = commandStr.trim().split(' ');
    const cmd = parts[0].toLowerCase();

    switch (cmd) {
      case '/say':
        if (instance && instance.bot) {
          instance.bot.chat(parts.slice(1).join(' '));
          instance.log('Command Execution', `Chat sent: ${parts.slice(1).join(' ')}`);
        }
        break;
      case '/goto':
        if (instance && instance.bot) {
          const x = parseFloat(parts[1]);
          const y = parseFloat(parts[2]);
          const z = parseFloat(parts[3]);
          const defaultMovements = new Movements(instance.bot);
          instance.bot.pathfinder.setMovements(defaultMovements);
          instance.bot.pathfinder.setGoal(new goals.GoalBlock(x, y, z));
          instance.log('Command Execution', `Pathfinding initiated to (${x}, ${y}, ${z})`);
        }
        break;
      case '/stopall':
        clusterManager.forEach(inst => inst.destroy());
        clusterManager.clear();
        io.emit('terminal_response', { status: 'success', message: 'All cluster bots forcibly terminated.' });
        break;
      case '/script':
        if (parts[1] === 'run' && parts[2]) {
          db.get('SELECT * FROM macros WHERE id = ?', [parts[2]], (e, row) => {
            if (row && instance) executeMacroDSL(instance, row.dsl_code);
          });
        }
        break;
      default:
        if (instance && instance.bot) instance.bot.chat(commandStr);
        break;
    }
  });

  socket.on('query_groq_assistant', async (data) => {
    const { prompt } = data;
    const reply = await queryGroqAI(prompt, 'DashboardUser');
    socket.emit('groq_assistant_reply', { reply });
  });
});

// API Routes for Bots & Cluster Management
app.get('/api/bots', requireAuth, (req, res) => {
  const query = req.session.user.role === 'admin' ? 'SELECT * FROM bots' : 'SELECT * FROM bots WHERE owner_id = ?';
  const params = req.session.user.role === 'admin' ? [] : [req.session.user.id];
  db.all(query, params, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/bots/create', requireAuth, (req, res) => {
  const { username, host, port, version, auth_mode, proxy, auto_auth_pass, webhook_url } = req.body;
  db.run(
    `INSERT INTO bots (owner_id, username, host, port, version, auth_mode, proxy, auto_auth_pass, webhook_url, is_active)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)`,
    [req.session.user.id, username, host, port || 25565, version || 'auto', auth_mode || 'offline', proxy || '', auto_auth_pass || '', webhook_url || ''],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      const botId = this.lastID;
      db.get('SELECT * FROM bots WHERE id = ?', [botId], (e, row) => {
        const inst = new ClusterBotInstance(row);
        clusterManager.set(botId, inst);
        inst.spawn();
        res.json({ success: true, bot: row });
      });
    }
  );
});

app.post('/api/bots/:id/action', requireAuth, (req, res) => {
  const botId = parseInt(req.params.id);
  const { action } = req.body;
  const instance = clusterManager.get(botId);

  if (action === 'start') {
    if (instance) instance.spawn();
    else {
      db.get('SELECT * FROM bots WHERE id = ?', [botId], (err, row) => {
        if (row) {
          const inst = new ClusterBotInstance(row);
          clusterManager.set(botId, inst);
          inst.spawn();
        }
      });
    }
  } else if (action === 'stop' && instance) {
    instance.destroy();
  }
  res.json({ success: true });
});

// Embedded Single-Page Web Dashboard Interface
app.get('*', (req, res) => {
  res.send(`<!DOCTYPE html>
<html lang="en" data-theme="cyberpunk">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Minecraft AFK Engine & Management Dashboard</title>
  <script src="/socket.io/socket.io.js"></script>
  <style>
    :root {
      --bg-base: #0a0a0f; --panel-bg: rgba(18, 18, 26, 0.75); --border-color: rgba(255, 255, 255, 0.12);
      --accent: #00f0ff; --accent-glow: rgba(0, 240, 255, 0.4); --text: #f0f0f5; --danger: #ff0055;
    }
    [data-theme="synthwave"] { --bg-base: #1a0b2e; --accent: #ff71ce; --accent-glow: rgba(255, 113, 206, 0.4); }
    [data-theme="dracula"] { --bg-base: #282a36; --accent: #bd93f9; --panel-bg: rgba(40, 42, 54, 0.8); }
    [data-theme="nord"] { --bg-base: #2e3440; --accent: #88c0d0; --panel-bg: rgba(46, 52, 64, 0.8); }
    [data-theme="matrix"] { --bg-base: #020d04; --accent: #00ff41; --panel-bg: rgba(5, 20, 8, 0.85); }
    [data-theme="obsidian"] { --bg-base: #000000; --accent: #ffffff; --panel-bg: rgba(20, 20, 20, 0.9); }
    [data-theme="oled"] { --bg-base: #000000; --accent: #39ff14; --panel-bg: #050505; }
    [data-theme="solarized"] { --bg-base: #002b36; --accent: #2aa198; --panel-bg: rgba(7, 54, 66, 0.85); }
    [data-theme="deepocean"] { --bg-base: #0b192c; --accent: #1e90ff; --panel-bg: rgba(30, 60, 90, 0.6); }
    [data-theme="sunset"] { --bg-base: #2d132c; --accent: #ff6464; --panel-bg: rgba(80, 30, 60, 0.7); }
    [data-theme="tokyonight"] { --bg-base: #1a1b26; --accent: #7aa2f7; --panel-bg: rgba(26, 27, 38, 0.85); }
    [data-theme="emerald"] { --bg-base: #062c19; --accent: #50fa7b; --panel-bg: rgba(10, 50, 30, 0.8); }
    [data-theme="crimson"] { --bg-base: #1a0000; --accent: #ff0000; --panel-bg: rgba(40, 0, 0, 0.8); }
    [data-theme="cybergold"] { --bg-base: #141000; --accent: #ffd700; --panel-bg: rgba(40, 32, 0, 0.8); }

    * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Segoe UI', Roboto, sans-serif; }
    body { background: var(--bg-base); color: var(--text); min-height: 100vh; overflow-x: hidden; }
    .glass { background: var(--panel-bg); backdrop-filter: blur(20px); border: 1px solid var(--border-color); border-radius: 12px; }
    
    header { padding: 1rem 2rem; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border-color); }
    header h1 { color: var(--accent); text-shadow: 0 0 10px var(--accent-glow); font-size: 1.4rem; }
    
    .container { display: grid; grid-template-columns: 320px 1fr; gap: 1.5rem; padding: 1.5rem; max-width: 1600px; margin: 0 auto; }
    .sidebar { display: flex; flex-direction: column; gap: 1rem; }
    .main-content { display: flex; flex-direction: column; gap: 1.5rem; }

    .card { padding: 1.2rem; }
    .card h3 { margin-bottom: 1rem; font-size: 1rem; color: var(--accent); }
    input, select, button { width: 100%; padding: 0.75rem; border-radius: 6px; border: 1px solid var(--border-color); background: rgba(0,0,0,0.4); color: #fff; margin-bottom: 0.75rem; }
    button { background: var(--accent); color: #000; font-weight: bold; cursor: pointer; border: none; transition: 0.2s ease; }
    button:hover { opacity: 0.9; box-shadow: 0 0 12px var(--accent-glow); }

    .bot-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 1rem; }
    .bot-card { position: relative; overflow: hidden; display: flex; flex-direction: column; gap: 0.75rem; }
    .bot-card-header { display: flex; align-items: center; gap: 1rem; }
    .bot-avatar { width: 48px; height: 48px; border-radius: 8px; background: #000; }
    .status-badge { position: absolute; top: 12px; right: 12px; padding: 4px 8px; border-radius: 20px; font-size: 0.7rem; font-weight: bold; }
    .status-CONNECTED { background: #00ff6622; color: #00ff66; border: 1px solid #00ff66; }
    .status-DISCONNECTED { background: #ff005522; color: #ff0055; border: 1px solid #ff0055; }
    
    .stat-bar { height: 8px; background: rgba(255,255,255,0.1); border-radius: 4px; overflow: hidden; margin-top: 4px; }
    .stat-fill { height: 100%; transition: width 0.3s ease; }
    
    .radar-canvas { width: 100%; height: 260px; background: #000; border-radius: 8px; }
    .inventory-grid { display: grid; grid-template-columns: repeat(9, 1fr); gap: 4px; }
    .inventory-slot { aspect-ratio: 1; background: rgba(0,0,0,0.6); border: 1px solid var(--border-color); border-radius: 4px; display: flex; align-items: center; justify-content: center; font-size: 0.65rem; position: relative; }
    .inventory-slot .count { position: absolute; bottom: 2px; right: 2px; font-weight: bold; }

    .terminal { height: 300px; background: #000; border-radius: 8px; padding: 1rem; font-family: monospace; font-size: 0.85rem; overflow-y: auto; display: flex; flex-direction: column; gap: 4px; }
    .terminal-line { word-break: break-all; }
    .category-System { color: #888; }
    .category-Chat { color: #00f0ff; }
    .category-AI { color: #bd93f9; }

    /* Finny Floating Assistant */
    .finny-widget { position: fixed; bottom: 24px; right: 24px; width: 320px; z-index: 999; display: flex; flex-direction: column; }
    .finny-header { padding: 0.75rem; background: var(--accent); color: #000; font-weight: bold; border-radius: 12px 12px 0 0; cursor: pointer; display: flex; justify-content: space-between; }
    .finny-body { height: 240px; padding: 0.75rem; overflow-y: auto; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem; }
  </style>
</head>
<body>
  <header class="glass">
    <h1>MINECRAFT AFK ENGINE ARCHITECT</h1>
    <div style="width: 200px;">
      <select id="themeSelect" onchange="switchTheme(this.value)">
        <option value="cyberpunk">Cyberpunk Neon</option>
        <option value="synthwave">Synthwave '84</option>
        <option value="dracula">Dracula</option>
        <option value="nord">Nord Dark</option>
        <option value="matrix">Matrix Terminal</option>
        <option value="obsidian">Obsidian Minimal</option>
        <option value="oled">OLED Pure Black</option>
        <option value="solarized">Solarized Midnight</option>
        <option value="deepocean">Deep Ocean</option>
        <option value="sunset">Sunset Violet</option>
        <option value="tokyonight">Tokyo Night</option>
        <option value="emerald">Emerald Forest</option>
        <option value="crimson">Crimson Blood</option>
        <option value="cybergold">Cyber Gold</option>
      </select>
    </div>
  </header>

  <div class="container">
    <div class="sidebar">
      <div class="card glass">
        <h3>Deploy Bot Instance</h3>
        <input type="text" id="botUsername" placeholder="Bot Username">
        <input type="text" id="botHost" placeholder="Target Server Host">
        <input type="number" id="botPort" value="25565" placeholder="Port">
        <select id="botAuth">
          <option value="offline">Offline / Cracked</option>
          <option value="microsoft">Microsoft OAuth</option>
        </select>
        <input type="password" id="botAutoAuth" placeholder="Auto-Auth Password">
        <input type="text" id="botWebhook" placeholder="Discord Webhook URL">
        <button onclick="deployBot()">Deploy to Cluster</button>
      </div>

      <div class="card glass">
        <h3>Spatial 2D Radar (32b Radius)</h3>
        <canvas id="radarCanvas" class="radar-canvas" width="280" height="260"></canvas>
      </div>
    </div>

    <div class="main-content">
      <div id="botCardsGrid" class="bot-grid"></div>

      <div class="card glass">
        <h3>Live Interactive Inventory (Selected Bot)</h3>
        <div id="inventoryContainer" class="inventory-grid"></div>
      </div>

      <div class="card glass">
        <h3>Cluster Terminal & Command Interceptor</h3>
        <div id="terminalLog" class="terminal"></div>
        <div style="display: flex; gap: 0.5rem; margin-top: 0.75rem;">
          <input type="text" id="terminalCmd" placeholder="Type slash command (e.g., /goto 100 64 -200, /say Hello, /stopall)" style="margin-bottom: 0;">
          <button onclick="sendTerminalCommand()" style="width: 120px;">Send</button>
        </div>
      </div>
    </div>
  </div>

  <!-- Finny Groq AI Widget -->
  <div class="finny-widget glass">
    <div class="finny-header" onclick="toggleFinny()">
      <span>🤖 Finny AI Assistant</span>
      <span id="finnyToggleText">▼</span>
    </div>
    <div id="finnyContent">
      <div id="finnyBody" class="finny-body">
        <div style="color: var(--accent);">Finny: Ready to assist with cluster operations.</div>
      </div>
      <div style="padding: 0.5rem;">
        <input type="text" id="finnyInput" placeholder="Ask Finny AI..." onkeypress="if(event.key==='Enter')askFinny()" style="margin: 0;">
      </div>
    </div>
  </div>

  <script>
    const socket = io();
    let selectedBotId = null;
    let botTelemetryMap = new Map();

    // Audio Synthesizer via Web Audio API
    const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    function playAudioSound(type) {
      if (audioCtx.state === 'suspended') audioCtx.resume();
      const osc = audioCtx.createOscillator();
      const gain = audioCtx.createGain();
      osc.connect(gain);
      gain.connect(audioCtx.destination);

      if (type === 'connect') {
        osc.frequency.setValueAtTime(440, audioCtx.currentTime);
        osc.frequency.exponentialRampToValueAtTime(880, audioCtx.currentTime + 0.2);
        gain.gain.setValueAtTime(0.1, audioCtx.currentTime);
        osc.start(); osc.stop(audioCtx.currentTime + 0.2);
      } else if (type === 'command') {
        osc.type = 'square';
        osc.frequency.setValueAtTime(600, audioCtx.currentTime);
        gain.gain.setValueAtTime(0.05, audioCtx.currentTime);
        osc.start(); osc.stop(audioCtx.currentTime + 0.05);
      }
    }

    function switchTheme(theme) {
      document.documentElement.setAttribute('data-theme', theme);
    }

    async function fetchBots() {
      const res = await fetch('/api/bots');
      if (res.ok) {
        const bots = await res.json();
        renderBotCards(bots);
      }
    }

    function renderBotCards(bots) {
      const grid = document.getElementById('botCardsGrid');
      grid.innerHTML = '';
      bots.forEach(bot => {
        if (!selectedBotId) selectedBotId = bot.id;
        const telemetry = botTelemetryMap.get(bot.id) || { health: 20, food: 20, ping: 0, pos: {x:0,y:0,z:0} };
        const card = document.createElement('div');
        card.className = 'card glass bot-card';
        card.onclick = () => { selectedBotId = bot.id; renderInventory(); };
        card.innerHTML = \`
          <span class="status-badge status-\${bot.is_active ? 'CONNECTED' : 'DISCONNECTED'}">\${bot.is_active ? 'CONNECTED' : 'DISCONNECTED'}</span>
          <div class="bot-card-header">
            <img class="bot-avatar" src="https://crafatar.com/renders/head/\${bot.username}?scale=3&default=MHO" alt="Avatar">
            <div>
              <h4 style="color:#fff;">\${bot.username}</h4>
              <p style="font-size:0.75rem; color:#888;">\${bot.host}:\${bot.port}</p>
            </div>
          </div>
          <div>
            <div style="font-size:0.75rem; display:flex; justify-content:space-between;"><span>Health</span><span>\${telemetry.health}/20</span></div>
            <div class="stat-bar"><div class="stat-fill" style="width:\${(telemetry.health/20)*100}%; background:#ff0055;"></div></div>
            <div style="font-size:0.75rem; display:flex; justify-content:space-between; margin-top:4px;"><span>Hunger</span><span>\${telemetry.food}/20</span></div>
            <div class="stat-bar"><div class="stat-fill" style="width:\${(telemetry.food/20)*100}%; background:#ffaa00;"></div></div>
          </div>
          <div style="font-size:0.75rem; color:#aaa; display:flex; justify-content:space-between; margin-top:4px;">
            <span>XYZ: \${telemetry.pos.x}, \${telemetry.pos.y}, \${telemetry.pos.z}</span>
            <span>\${telemetry.ping}ms</span>
          </div>
          <div style="display:flex; gap:0.5rem; margin-top:0.5rem;">
            <button onclick="event.stopPropagation(); triggerAction(\${bot.id}, 'start')">Start</button>
            <button onclick="event.stopPropagation(); triggerAction(\${bot.id}, 'stop')" style="background:var(--danger); color:#fff;">Stop</button>
          </div>
        \`;
        grid.appendChild(card);
      });
    }

    async function deployBot() {
      const username = document.getElementById('botUsername').value;
      const host = document.getElementById('botHost').value;
      const port = document.getElementById('botPort').value;
      const auth_mode = document.getElementById('botAuth').value;
      const auto_auth_pass = document.getElementById('botAutoAuth').value;
      const webhook_url = document.getElementById('botWebhook').value;

      if (!username || !host) return alert('Username and Host are required!');

      const res = await fetch('/api/bots/create', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ username, host, port, auth_mode, auto_auth_pass, webhook_url })
      });
      if (res.ok) {
        playAudioSound('connect');
        fetchBots();
      }
    }

    async function triggerAction(botId, action) {
      await fetch(\`/api/bots/\${botId}/action\`, {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ action })
      });
      playAudioSound('command');
      fetchBots();
    }

    // Socket Telemetry Receiver
    socket.on('bot_telemetry', (data) => {
      botTelemetryMap.set(data.botId, data);
      if (data.botId === selectedBotId) {
        renderRadar(data.entities, data.yaw);
        renderInventory(data.inventory);
      }
    });

    socket.on('bot_log', (data) => {
      const logBox = document.getElementById('terminalLog');
      const line = document.createElement('div');
      line.className = \`terminal-line category-\${data.log.category}\`;
      line.innerText = \`[\${data.log.timestamp}] [\${data.log.category}] \${data.log.message}\`;
      logBox.appendChild(line);
      logBox.scrollTop = logBox.scrollHeight;
    });

    // 2D Canvas Radar Rendering
    function renderRadar(entities = [], yaw = 0) {
      const canvas = document.getElementById('radarCanvas');
      const ctx = canvas.getContext('2d');
      ctx.clearRect(0, 0, canvas.width, canvas.height);

      const cx = canvas.width / 2;
      const cy = canvas.height / 2;
      const scale = canvas.width / 64; // 32 block radius

      // Grid Rings
      ctx.strokeStyle = '#222';
      ctx.beginPath(); ctx.arc(cx, cy, scale * 10, 0, Math.PI * 2); ctx.stroke();
      ctx.beginPath(); ctx.arc(cx, cy, scale * 20, 0, Math.PI * 2); ctx.stroke();
      ctx.beginPath(); ctx.arc(cx, cy, scale * 30, 0, Math.PI * 2); ctx.stroke();

      // Render Central Arrow (Bot)
      ctx.save();
      ctx.translate(cx, cy);
      ctx.rotate(yaw || 0);
      ctx.fillStyle = '#00f0ff';
      ctx.beginPath(); ctx.moveTo(0, -8); ctx.lineTo(6, 6); ctx.lineTo(-6, 6); ctx.closePath(); ctx.fill();
      ctx.restore();

      // Entities
      entities.forEach(ent => {
        const ex = cx + (ent.x * scale);
        const ey = cy + (ent.z * scale);
        ctx.fillStyle = ent.type === 'player' ? '#00f0ff' : ent.type === 'mob' ? '#ff0055' : '#00ff66';
        ctx.beginPath(); ctx.arc(ex, ey, 4, 0, Math.PI * 2); ctx.fill();
      });
    }

    function renderInventory(slots = []) {
      const container = document.getElementById('inventoryContainer');
      container.innerHTML = '';
      for (let i = 0; i < 36; i++) {
        const item = slots.find(s => s.slot === i) || { name: 'empty', count: 0 };
        const slotEl = document.createElement('div');
        slotEl.className = 'inventory-slot';
        slotEl.innerText = item.name !== 'empty' ? item.name.substring(0, 4) : '';
        if (item.count > 1) {
          const cnt = document.createElement('span');
          cnt.className = 'count';
          cnt.innerText = item.count;
          slotEl.appendChild(cnt);
        }
        container.appendChild(slotEl);
      }
    }

    function sendTerminalCommand() {
      const cmdInput = document.getElementById('terminalCmd');
      const commandStr = cmdInput.value;
      if (!commandStr || !selectedBotId) return;
      socket.emit('register_terminal_command', { botId: selectedBotId, commandStr });
      cmdInput.value = '';
      playAudioSound('command');
    }

    // Finny Assistant Interactive Logic
    function toggleFinny() {
      const content = document.getElementById('finnyContent');
      const text = document.getElementById('finnyToggleText');
      if (content.style.display === 'none') {
        content.style.display = 'block'; text.innerText = '▼';
      } else {
        content.style.display = 'none'; text.innerText = '▲';
      }
    }

    function askFinny() {
      const input = document.getElementById('finnyInput');
      const prompt = input.value;
      if (!prompt) return;

      const body = document.getElementById('finnyBody');
      body.innerHTML += \`<div style="color:#fff;">You: \${prompt}</div>\`;
      socket.emit('query_groq_assistant', { prompt });
      input.value = '';
      body.scrollTop = body.scrollHeight;
    }

    socket.on('groq_assistant_reply', (data) => {
      const body = document.getElementById('finnyBody');
      body.innerHTML += \`<div style="color:var(--accent);">Finny: \${data.reply}</div>\`;
      body.scrollTop = body.scrollHeight;
    });

    // Boot Init
    fetchBots();
  </script>
</body>
</html>`);
});

// OS Signal Trap & Graceful Cluster Shutdown
function gracefulShutdown(signal) {
  console.log(`[OS SIGNAL ${signal}] Initiating clean cluster shutdown...`);
  
  clusterManager.forEach((instance) => {
    instance.destroy();
  });

  db.close((err) => {
    if (err) console.error('[DB CLOSE ERROR]', err.message);
    else console.log('[DB] Persistent SQLite connection closed.');
    
    server.close(() => {
      console.log('[HTTP] Socket & Express Server closed cleanly.');
      process.exit(0);
    });
  });

  setTimeout(() => {
    console.warn('[FORCED EXIT] Emergency termination timeout reached.');
    process.exit(1);
  }, 5000);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// Server Launch
server.listen(PORT, () => {
  console.log(`=======================================================`);
  console.log(`MINECRAFT AFK CLUSTER ENGINE ACTIVE ON PORT ${PORT}`);
  console.log(`Dashboard UI: http://localhost:${PORT}`);
  console.log(`Environment: ${process.env.NODE_ENV || 'production'}`);
  console.log(`=======================================================`);
});
EOF

# Production Runtime Container Config
ENV NODE_ENV=production
ENV PORT=3000

EXPOSE 3000

# Execute Process Launch
CMD ["node", "bot.js"]
