# syntax=docker/dockerfile:1.4
FROM node:18-alpine

# Set timezone, update packages, install sqlite system deps
RUN apk add --no-cache tzdata sqlite

WORKDIR /app

# Ensure data directory exists for persistent SQLite WAL storage
RUN mkdir -p /app/data

# Heredoc injection of the monolithic Node.js engine
COPY <<-"EOF" /app/bot.js
const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');

// ==========================================
// 1. RUNTIME AUTO-BOOTSTRAPPER
// ==========================================
if (!fs.existsSync('./package.json')) {
    console.log("[SYSTEM] Initializing package.json...");
    fs.writeFileSync('./package.json', JSON.stringify({
        name: "enterprise-afk-bot-engine",
        version: "1.0.0",
        main: "bot.js",
        type: "commonjs"
    }));
    const deps = "express@^4.19.0 socket.io@^4.7.0 dotenv@^16.4.0 helmet@^7.1.0 cors@^2.8.5 " +
        "mineflayer@^4.20.0 mineflayer-pathfinder@^2.4.0 mineflayer-auto-eat@^1.4.0 " +
        "mineflayer-armor-manager@^2.0.1 mineflayer-collectblock@^1.6.0 mineflayer-pvp@^1.3.0 vec3@^0.1.10 " +
        "@groq/groq-sdk@^0.5.0 bcryptjs@^2.4.3 express-session@^1.18.0 connect-sqlite3@^0.9.15 " +
        "express-rate-limit@^7.2.0 sqlite3@^5.1.7 socks-proxy-agent@^8.0.3 axios@^1.6.8";
    console.log("[SYSTEM] Installing Dependencies... This will take a moment.");
    execSync(`npm install ${deps}`, { stdio: 'inherit' });
}

// ==========================================
// 2. IMPORTS & ENVIRONMENT
// ==========================================
require('dotenv').config();
const express = require('express');
const http = require('http');
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
const { pathfinder, Movements, goals } = require('mineflayer-pathfinder');
const autoeat = require('mineflayer-auto-eat').plugin;
const armorManager = require('mineflayer-armor-manager');
const collectBlock = require('mineflayer-collectblock').plugin;
const pvp = require('mineflayer-pvp').plugin;
const { Vec3 } = require('vec3');

const app = express();
const server = http.createServer(app);
const io = new Server(server, { pingInterval: 20000, pingTimeout: 45000 });
const PORT = process.env.PORT || 3000;
const groq = new Groq({ apiKey: process.env.GROQ_API_KEY || 'MISSING_KEY' });

// ==========================================
// 3. DATABASE (WAL MODE) & SCHEMAS
// ==========================================
const dbPath = path.join(__dirname, 'data', 'system.db');
const db = new sqlite3.Database(dbPath);
db.serialize(() => {
    db.run("PRAGMA journal_mode = WAL;");
    db.run("PRAGMA synchronous = NORMAL;");
    db.run(`CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, username TEXT UNIQUE, password TEXT, role TEXT)`);
    db.run(`CREATE TABLE IF NOT EXISTS bots (id INTEGER PRIMARY KEY, owner_id INTEGER, name TEXT, host TEXT, port INTEGER, version TEXT, auth_mode TEXT, proxy TEXT, is_active INTEGER DEFAULT 1)`);
    db.run(`CREATE TABLE IF NOT EXISTS system_logs (id INTEGER PRIMARY KEY, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, type TEXT, message TEXT)`);
    // Seed Admin
    db.get("SELECT * FROM users WHERE username = 'admin'", async (err, row) => {
        if (!row) {
            const hash = await bcrypt.hash(process.env.ADMIN_PASSWORD || 'admin', 12);
            db.run("INSERT INTO users (username, password, role) VALUES (?, ?, ?)", ['admin', hash, 'admin']);
        }
    });
});

// ==========================================
// 4. EMBEDDED FRONTEND UI (SPA)
// ==========================================
const FRONTEND_HTML = `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Enterprise AFK Bot Engine</title>
    <script src="/socket.io/socket.io.js"></script>
    <style>
        :root { --bg: #0f0f13; --panel: rgba(25,25,30,0.6); --border: rgba(255,255,255,0.1); --text: #eee; --accent: #00ffcc; }
        body.theme-dracula { --bg: #282a36; --panel: rgba(68,71,90,0.6); --accent: #ff79c6; }
        body.theme-cyber { --bg: #000; --panel: rgba(0,20,0,0.6); --accent: #ff003c; border-color: #00ff00;}
        body { margin: 0; font-family: 'Segoe UI', system-ui; background: var(--bg); color: var(--text); overflow-x: hidden; }
        .glass { background: var(--panel); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border: 1px solid var(--border); border-radius: 12px; }
        .grid-layout { display: grid; grid-template-columns: 300px 1fr 350px; gap: 15px; padding: 15px; height: 95vh; }
        .panel { display: flex; flex-direction: column; padding: 15px; overflow-y: auto; }
        h2 { margin-top:0; color: var(--accent); font-size: 1.1rem; text-transform: uppercase; letter-spacing: 1px;}
        input, select, button { background: rgba(0,0,0,0.3); border: 1px solid var(--border); color: var(--text); padding: 8px 12px; border-radius: 6px; outline: none; margin-bottom: 8px; width: 100%; box-sizing: border-box; }
        button { background: var(--accent); color: #000; font-weight: bold; cursor: pointer; transition: 0.2s; }
        button:hover { opacity: 0.8; transform: scale(0.98); }
        .bot-card { display: flex; align-items: center; gap: 10px; padding: 10px; background: rgba(0,0,0,0.4); border-radius: 8px; margin-bottom: 10px; cursor: pointer;}
        .bot-card img { width: 40px; height: 40px; border-radius: 4px; }
        .bot-stats { font-size: 0.8rem; color: #aaa; }
        .bot-stats span { display: inline-block; margin-right: 8px; }
        .status { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
        .status.connected { background: #00ff00; box-shadow: 0 0 8px #00ff00; }
        .status.disconnected { background: #ff0000; box-shadow: 0 0 8px #ff0000; }
        #terminal { flex: 1; background: rgba(0,0,0,0.8); font-family: 'Courier New', monospace; font-size: 0.85rem; padding: 10px; overflow-y: auto; color: #0f0; border-radius: 8px; margin-bottom:10px; }
        .log-sys { color: #8be9fd; } .log-err { color: #ff5555; } .log-chat { color: #f1fa8c; } .log-ai { color: #bd93f9; }
        #radar-container { display:flex; justify-content:center; margin-bottom: 15px;}
        canvas#radar { background: rgba(0,0,0,0.5); border-radius: 50%; border: 2px solid var(--accent); }
        .inv-grid { display: grid; grid-template-columns: repeat(9, 1fr); gap: 2px; background: #8b8b8b; padding: 4px; border: 2px solid #373737; }
        .inv-slot { aspect-ratio: 1; background: #8b8b8b; border-top: 2px solid #fff; border-left: 2px solid #fff; border-bottom: 2px solid #373737; border-right: 2px solid #373737; position: relative;}
        .inv-slot img { width: 100%; height: 100%; image-rendering: pixelated; }
        .inv-count { position: absolute; bottom: 0; right: 2px; font-size: 0.7rem; font-weight: bold; color: white; text-shadow: 1px 1px 0 #000; }
        #finny { position: fixed; bottom: 20px; right: 20px; width: 60px; height: 60px; background: var(--accent); border-radius: 30px; cursor: pointer; box-shadow: 0 8px 16px rgba(0,0,0,0.3); z-index: 100; transition: width 0.3s, height 0.3s, border-radius 0.3s; overflow: hidden; display:flex; align-items:center; justify-content:center; font-weight:bold; color:#000; }
        #finny.expanded { width: 300px; height: 400px; border-radius: 12px; flex-direction: column; padding: 10px; align-items:stretch; justify-content:flex-start;}
        #finny-chat { flex:1; overflow-y:auto; font-size: 0.85rem; margin-bottom:10px; display:none; }
        #finny.expanded #finny-chat { display:block; }
        #finny-input { display:none; width: 100%; box-sizing: border-box; }
        #finny.expanded #finny-input { display:block; }
        #finny.expanded .finny-icon { display: none; }
        /* Auth Overlay */
        #auth-overlay { position: fixed; top:0; left:0; width: 100vw; height: 100vh; background: rgba(0,0,0,0.9); display:flex; align-items:center; justify-content:center; z-index: 9999; }
        #auth-box { width: 300px; }
    </style>
</head>
<body>
    <div id="auth-overlay" class="glass">
        <div id="auth-box" class="glass panel">
            <h2>Authentication</h2>
            <input type="text" id="auth-user" placeholder="Username">
            <input type="password" id="auth-pass" placeholder="Password">
            <button onclick="login()">Login</button>
            <div id="auth-err" style="color:red; font-size:0.8rem; margin-top:5px;"></div>
        </div>
    </div>

    <div class="grid-layout">
        <div class="glass panel">
            <h2>Bot Cluster</h2>
            <div id="bot-list"></div>
            <h2 style="margin-top:20px;">Deploy Bot</h2>
            <input type="text" id="new-bot-name" placeholder="Username / Email">
            <input type="text" id="new-bot-host" placeholder="Server IP">
            <input type="number" id="new-bot-port" placeholder="Port" value="25565">
            <select id="new-bot-ver"><option value="false">Auto Version</option><option value="1.20.4">1.20.4</option><option value="1.19.4">1.19.4</option><option value="1.18.2">1.18.2</option><option value="1.8.9">1.8.9</option></select>
            <select id="new-bot-auth"><option value="offline">Offline / Cracked</option><option value="microsoft">Microsoft (OAuth)</option></select>
            <input type="text" id="new-bot-proxy" placeholder="Proxy (host:port)">
            <button onclick="deployBot()">Deploy Instance</button>
            <h2 style="margin-top:20px;">Settings</h2>
            <select id="theme-select" onchange="document.body.className = 'theme-' + this.value">
                <option value="default">Default Dark</option>
                <option value="dracula">Dracula</option>
                <option value="cyber">Cyberpunk</option>
            </select>
        </div>

        <div class="glass panel" style="padding:0;">
            <div id="terminal"></div>
            <input type="text" id="term-input" placeholder="Enter /command or message... (Press Enter)" style="margin:10px; width:calc(100% - 20px); border-radius:0;">
        </div>

        <div class="glass panel">
            <h2>Spatial Radar (32b)</h2>
            <div id="radar-container"><canvas id="radar" width="200" height="200"></canvas></div>
            <h2>Inventory Grid</h2>
            <div class="inv-grid" id="inventory"></div>
            <h2 style="margin-top:15px;">Selected Bot Stats</h2>
            <div id="active-bot-stats" class="bot-stats">Select a bot to view telemetry.</div>
        </div>
    </div>

    <div id="finny" onclick="toggleFinny(event)">
        <span class="finny-icon">🐟</span>
        <div id="finny-chat"><b>Finny AI:</b> How can I orchestrate the cluster for you today?</div>
        <input type="text" id="finny-input" placeholder="Ask Finny..." onkeypress="if(event.key==='Enter') sendFinny(event)">
    </div>

    <script>
        const socket = io({ autoConnect: false });
        let token = localStorage.getItem('token');
        let selectedBot = null;
        let radarEntities = [];
        
        // Audio Synth
        const AudioContext = window.AudioContext || window.webkitAudioContext;
        const audioCtx = new AudioContext();
        function playSound(type) {
            if(audioCtx.state === 'suspended') audioCtx.resume();
            const osc = audioCtx.createOscillator();
            const gain = audioCtx.createGain();
            osc.connect(gain); gain.connect(audioCtx.destination);
            if(type==='connect'){ osc.type='sine'; osc.frequency.setValueAtTime(440, audioCtx.currentTime); osc.frequency.exponentialRampToValueAtTime(880, audioCtx.currentTime + 0.1); gain.gain.setValueAtTime(0.1, audioCtx.currentTime); gain.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + 0.5); osc.start(); osc.stop(audioCtx.currentTime + 0.5); }
            if(type==='disconnect'){ osc.type='sawtooth'; osc.frequency.setValueAtTime(200, audioCtx.currentTime); osc.frequency.linearRampToValueAtTime(50, audioCtx.currentTime + 0.3); gain.gain.setValueAtTime(0.1, audioCtx.currentTime); gain.gain.linearRampToValueAtTime(0.01, audioCtx.currentTime + 0.3); osc.start(); osc.stop(audioCtx.currentTime + 0.3); }
            if(type==='msg'){ osc.type='square'; osc.frequency.setValueAtTime(600, audioCtx.currentTime); gain.gain.setValueAtTime(0.05, audioCtx.currentTime); gain.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + 0.1); osc.start(); osc.stop(audioCtx.currentTime + 0.1); }
        }

        async function login() {
            const u = document.getElementById('auth-user').value;
            const p = document.getElementById('auth-pass').value;
            const res = await fetch('/api/login', { method: 'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({u,p})});
            if(res.ok) { const data = await res.json(); token = data.token; localStorage.setItem('token', token); document.getElementById('auth-overlay').style.display='none'; initSocket(); }
            else { document.getElementById('auth-err').innerText = "Invalid credentials"; }
        }

        if(token) { document.getElementById('auth-overlay').style.display='none'; initSocket(); }

        function initSocket() {
            socket.io.opts.query = { token };
            socket.connect();
            
            socket.on('log', (data) => {
                const term = document.getElementById('terminal');
                const div = document.createElement('div');
                div.className = 'log-' + data.type;
                div.innerText = \`[\${new Date().toLocaleTimeString()}] \${data.msg}\`;
                term.appendChild(div);
                if(term.childElementCount > 1500) term.removeChild(term.firstChild);
                term.scrollTop = term.scrollHeight;
                if(data.type === 'chat') playSound('msg');
            });

            socket.on('bots_update', (bots) => {
                const list = document.getElementById('bot-list');
                list.innerHTML = '';
                bots.forEach(b => {
                    const div = document.createElement('div');
                    div.className = 'bot-card';
                    div.onclick = () => selectBot(b);
                    div.innerHTML = \`<img src="https://crafatar.com/renders/head/\${b.uuid || '8667ba71-b85a-4004-af54-457a9734eed7'}" crossorigin="anonymous">
                    <div style="flex:1">
                        <div style="font-weight:bold;">\${b.name} <span class="status \${b.status}"></span></div>
                        <div class="bot-stats">❤ \${b.health||20} | 🍗 \${b.food||20} | \${b.host}</div>
                    </div>\`;
                    list.appendChild(div);
                });
            });

            socket.on('radar_data', (data) => {
                if(selectedBot && selectedBot.name === data.bot) radarEntities = data.entities;
            });
            
            socket.on('inventory_data', (data) => {
                if(selectedBot && selectedBot.name === data.bot) renderInventory(data.items);
            });
        }

        function selectBot(b) {
            selectedBot = b;
            document.getElementById('active-bot-stats').innerHTML = \`
                Position: X:\${b.pos?.x||0} Y:\${b.pos?.y||0} Z:\${b.pos?.z||0}<br>
                Dimension: \${b.dimension||'Overworld'}<br>
                Ping: \${b.ping||0}ms<br>Proxy: \${b.proxy || 'None'}
            \`;
            socket.emit('request_inventory', b.name);
        }

        function deployBot() {
            socket.emit('command', \`/add \${document.getElementById('new-bot-name').value} \${document.getElementById('new-bot-host').value} \${document.getElementById('new-bot-port').value} \${document.getElementById('new-bot-ver').value} \${document.getElementById('new-bot-auth').value} \${document.getElementById('new-bot-proxy').value}\`);
        }

        document.getElementById('term-input').addEventListener('keypress', (e) => {
            if(e.key === 'Enter') {
                const val = e.target.value;
                if(val.startsWith('/')) socket.emit('command', val);
                else if (selectedBot) socket.emit('command', \`/say \${selectedBot.name} \${val}\`);
                e.target.value = '';
            }
        });

        // 2D Radar Canvas Loop
        const canvas = document.getElementById('radar');
        const ctx = canvas.getContext('2d');
        function drawRadar() {
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            ctx.strokeStyle = 'rgba(0, 255, 204, 0.2)';
            ctx.beginPath(); ctx.arc(100, 100, 100, 0, Math.PI*2); ctx.stroke();
            ctx.beginPath(); ctx.arc(100, 100, 50, 0, Math.PI*2); ctx.stroke();
            
            // Draw Bot Center
            ctx.fillStyle = '#00ffcc';
            ctx.beginPath(); ctx.arc(100, 100, 3, 0, Math.PI*2); ctx.fill();

            radarEntities.forEach(e => {
                // Map relative coordinates (scale: 32 blocks = 100px radius -> ~3px per block)
                const rx = (e.x) * 3;
                const rz = (e.z) * 3;
                const px = 100 + rx;
                const py = 100 + rz;
                if(Math.hypot(rx, rz) > 100) return; // limit to 32b
                
                ctx.fillStyle = e.type === 'player' ? '#0ff' : e.type === 'hostile' ? '#f00' : e.type === 'item' ? '#ff0' : '#0f0';
                ctx.beginPath(); ctx.arc(px, py, 2, 0, Math.PI*2); ctx.fill();
            });
            requestAnimationFrame(drawRadar);
        }
        drawRadar();

        // Inventory Render
        function renderInventory(items) {
            const grid = document.getElementById('inventory');
            grid.innerHTML = '';
            for(let i=9; i<45; i++) {
                const item = items.find(x => x.slot === i);
                const slotDiv = document.createElement('div');
                slotDiv.className = 'inv-slot';
                if(item) {
                    slotDiv.innerHTML = \`<img src="https://raw.githubusercontent.com/PrismarineJS/minecraft-assets/master/data/1.19.4/items/\${item.name}.png" onerror="this.style.display='none'">
                    <div class="inv-count">\${item.count>1?item.count:''}</div>\`;
                }
                grid.appendChild(slotDiv);
            }
        }

        // Finny AI UI
        function toggleFinny(e) {
            if(e.target.id === 'finny-input') return;
            const f = document.getElementById('finny');
            f.classList.toggle('expanded');
        }
        function sendFinny(e) {
            const inp = document.getElementById('finny-input');
            const chat = document.getElementById('finny-chat');
            chat.innerHTML += \`<br><b style="color:#000">You:</b> \${inp.value}\`;
            socket.emit('ai_request', inp.value);
            inp.value = '';
            chat.scrollTop = chat.scrollHeight;
        }
        socket.on('ai_response', msg => {
            const chat = document.getElementById('finny-chat');
            chat.innerHTML += \`<br><b style="color:#fff">Finny:</b> \${msg}\`;
            chat.scrollTop = chat.scrollHeight;
        });

    </script>
</body>
</html>
`;

// ==========================================
// 5. EXPRESS & MIDDLEWARE
// ==========================================
app.use(helmet({ contentSecurityPolicy: false })); // Relaxed for local inline scripts & Crafatar imgs
app.use(cors());
app.use(express.json());
app.use(session({
    store: new SQLiteStore({ dir: './data', db: 'sessions.db' }),
    secret: process.env.SESSION_SECRET || 'fallback_enterprise_secret_99',
    resave: false,
    saveUninitialized: false,
    cookie: { secure: false, maxAge: 7 * 24 * 60 * 60 * 1000 }
}));

const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 5 });
app.post('/api/login', authLimiter, (req, res) => {
    db.get("SELECT * FROM users WHERE username = ?", [req.body.u], (err, row) => {
        if (row && bcrypt.compareSync(req.body.p, row.password)) {
            req.session.userId = row.id;
            req.session.role = row.role;
            // Generate simple static token for socket auth (In real prod, use JWT)
            const token = Buffer.from(`${row.id}:${row.role}:${Date.now()}`).toString('base64');
            res.json({ success: true, token });
        } else {
            res.status(401).json({ error: 'Unauthorized' });
        }
    });
});

app.get('/', (req, res) => res.send(FRONTEND_HTML));

// ==========================================
// 6. MINEFLAYER CLUSTER ORCHESTRATOR
// ==========================================
class BotCluster {
    constructor() {
        this.bots = new Map();
        this.reconnectAttempts = new Map();
    }

    async spawn(config, emitLog) {
        if (this.bots.has(config.name)) return emitLog('err', `Bot ${config.name} already exists.`);
        emitLog('sys', `Initializing bot ${config.name} -> ${config.host}:${config.port}`);
        
        let proxyAgent = null;
        if (config.proxy && config.proxy !== 'undefined' && config.proxy !== '') {
            try {
                proxyAgent = new SocksProxyAgent(`socks5://${config.proxy}`);
                emitLog('sys', `Routing ${config.name} via SOCKS5: ${config.proxy}`);
            } catch (e) { emitLog('err', `Proxy Error: ${e.message}`); }
        }

        const botOpts = {
            host: config.host,
            port: parseInt(config.port) || 25565,
            username: config.name,
            version: config.version === 'false' ? false : config.version,
            auth: config.auth_mode,
            agent: proxyAgent,
            hideErrors: true
        };

        let bot;
        try { bot = mineflayer.createBot(botOpts); } 
        catch (err) { return emitLog('err', `Spawn failed: ${err.message}`); }

        const botState = { 
            instance: bot, 
            config, 
            status: 'connecting',
            health: 20, food: 20, pos: {x:0,y:0,z:0}, ping: 0, uuid: null,
            intervals: []
        };
        this.bots.set(config.name, botState);

        bot.loadPlugin(pathfinder);
        bot.loadPlugin(autoeat);
        bot.loadPlugin(armorManager);
        bot.loadPlugin(collectBlock);
        bot.loadPlugin(pvp);

        bot.on('login', () => {
            botState.status = 'connected';
            botState.uuid = bot.player?.uuid;
            this.reconnectAttempts.set(config.name, 0);
            emitLog('sys', `[${config.name}] Joined game.`);
            
            // Auto Eat Config
            bot.autoEat.options.priority = "foodPoints";
            bot.autoEat.options.bannedFood = ["rotten_flesh", "spider_eye", "poisonous_potato", "pufferfish"];
            bot.autoEat.options.startAt = 14;

            // Anti-AFK Engine (Heuristic)
            botState.intervals.push(setInterval(() => {
                if(Math.random() > 0.5) {
                    bot.setControlState('sneak', true);
                    setTimeout(() => bot.setControlState('sneak', false), 400 + Math.random()*500);
                }
                const yaw = bot.entity.yaw + (Math.random() - 0.5);
                const pitch = bot.entity.pitch + (Math.random() - 0.5) * 0.5;
                bot.look(yaw, pitch, true);
                if(Math.random() > 0.8) bot.setControlState('jump', true);
                setTimeout(() => bot.setControlState('jump', false), 100);
            }, 30000 + Math.random() * 60000)); // Every 30-90s

            // Spatial Radar Tick
            botState.intervals.push(setInterval(() => {
                if(!bot.entity) return;
                botState.pos = bot.entity.position;
                const entities = Object.values(bot.entities).map(e => {
                    if(e === bot.entity) return null;
                    const type = e.type === 'player' ? 'player' : (e.kind === 'Hostile mobs' ? 'hostile' : (e.type === 'object' ? 'item' : 'passive'));
                    return { x: e.position.x - botState.pos.x, z: e.position.z - botState.pos.z, type };
                }).filter(Boolean);
                io.emit('radar_data', { bot: config.name, entities });
            }, 1000)); // 1 Hz radar
        });

        bot.on('health', () => {
            botState.health = Math.round(bot.health);
            botState.food = Math.round(bot.food);
            // Hazard Guard
            if(bot.health <= 6) emitLog('err', `[${config.name}] LOW HEALTH WARNING!`);
            const blockUnder = bot.blockAt(bot.entity.position.offset(0, -1, 0));
            if(blockUnder && (blockUnder.name.includes('lava') || blockUnder.name.includes('fire'))) {
                emitLog('sys', `[${config.name}] Hazard detected. Attempting escape.`);
                const p = bot.entity.position;
                bot.pathfinder.setGoal(new goals.GoalNear(p.x + 3, p.y, p.z + 3, 1));
            }
        });

        bot.on('messagestr', async (msg) => {
            emitLog('chat', `[${config.name}] ${msg}`);
            // Auto-Auth Interceptor
            if(/(register|login|Please log in|Type \/auth)/i.test(msg)) {
                setTimeout(() => {
                    bot.chat(`/login ${process.env.ADMIN_PASSWORD || 'secret'}`);
                    bot.chat(`/register ${process.env.ADMIN_PASSWORD || 'secret'} ${process.env.ADMIN_PASSWORD || 'secret'}`);
                }, 800 + Math.random() * 1400);
            }
            
            // In-Game NLP (Groq)
            if(msg.includes('!ai ')) {
                const prompt = msg.split('!ai ')[1];
                try {
                    const chatCompletion = await groq.chat.completions.create({
                        messages: [{ role: 'user', content: `You are a Minecraft bot named ${config.name}. Reply in under 200 chars to: ${prompt}` }],
                        model: 'llama-3.3-70b-versatile',
                    });
                    bot.chat(chatCompletion.choices[0]?.message?.content || 'AI unavailable');
                } catch(e) {}
            }
        });

        bot.on('kicked', (reason) => emitLog('err', `[${config.name}] Kicked: ${reason}`));
        bot.on('error', (err) => emitLog('err', `[${config.name}] Error: ${err.message}`));
        bot.on('end', (reason) => {
            botState.status = 'disconnected';
            botState.intervals.forEach(clearInterval);
            bot.removeAllListeners();
            emitLog('sys', `[${config.name}] Disconnected. (${reason})`);
            
            // Jittered Exponential Backoff Reconnect
            let attempts = this.reconnectAttempts.get(config.name) || 0;
            if(attempts < 10) {
                attempts++;
                this.reconnectAttempts.set(config.name, attempts);
                const delay = Math.min(3000 * Math.pow(1.5, attempts) + Math.random() * 1000, 180000);
                emitLog('sys', `[${config.name}] Reconnecting in ${Math.round(delay/1000)}s... (Attempt ${attempts})`);
                setTimeout(() => {
                    this.bots.delete(config.name);
                    this.spawn(config, emitLog);
                }, delay);
            }
        });
    }

    async runMacro(botName, script, emitLog) {
        const botState = this.bots.get(botName);
        if(!botState) return emitLog('err', 'Bot not found for macro.');
        const bot = botState.instance;
        const lines = script.split('\n');
        for (let line of lines) {
            const parts = line.trim().split(' ');
            const cmd = parts[0].toUpperCase();
            try {
                if(cmd === 'DELAY') await new Promise(r => setTimeout(r, parseInt(parts[1])));
                if(cmd === 'SAY') bot.chat(parts.slice(1).join(' '));
                if(cmd === 'MOVE') {
                    bot.setControlState(parts[1].toLowerCase(), true);
                    await new Promise(r => setTimeout(r, parseInt(parts[2])));
                    bot.setControlState(parts[1].toLowerCase(), false);
                }
                if(cmd === 'LOOK') await bot.look(parseFloat(parts[1]), parseFloat(parts[2]), true);
                if(cmd === 'DROP_ALL') {
                    const items = bot.inventory.items();
                    for(let item of items) { await bot.tossStack(item); await new Promise(r=>setTimeout(r,500)); }
                }
            } catch(e) { emitLog('err', `Macro Error on ${line}: ${e.message}`); }
        }
    }

    remove(botName) {
        const botState = this.bots.get(botName);
        if(botState) {
            botState.intervals.forEach(clearInterval);
            this.reconnectAttempts.set(botName, 999); // Prevent auto-reconnect
            botState.instance.quit('Terminated by Dashboard');
            this.bots.delete(botName);
        }
    }

    getClusterData() {
        return Array.from(this.bots.values()).map(b => ({
            name: b.config.name, host: b.config.host, status: b.status,
            health: b.health, food: b.food, pos: b.pos, ping: b.instance?.player?.ping, uuid: b.uuid,
            dimension: b.instance?.game?.dimension, proxy: b.config.proxy
        }));
    }
}

const cluster = new BotCluster();

// ==========================================
// 7. WEBSOCKET CONTROLLER (Socket.io)
// ==========================================
io.use((socket, next) => {
    const token = socket.handshake.query.token;
    if(token) return next();
    return next(new Error('Authentication error'));
});

io.on('connection', (socket) => {
    const emitLog = (type, msg) => socket.emit('log', { type, msg });
    emitLog('sys', 'Connected to Engine Hub.');

    // Status Loop
    const syncInt = setInterval(() => socket.emit('bots_update', cluster.getClusterData()), 2000);
    socket.on('disconnect', () => clearInterval(syncInt));

    // Terminal Commands Parser
    socket.on('command', (cmdString) => {
        const args = cmdString.split(' ');
        const cmd = args[0];
        
        if (cmd === '/add' && args.length >= 3) {
            const config = { name: args[1], host: args[2], port: args[3]||25565, version: args[4], auth_mode: args[5]||'offline', proxy: args[6] };
            db.run("INSERT INTO bots (name, host, port, version, auth_mode, proxy) VALUES (?,?,?,?,?,?)", [config.name, config.host, config.port, config.version, config.auth_mode, config.proxy]);
            cluster.spawn(config, emitLog);
        }
        else if (cmd === '/remove' && args[1]) {
            cluster.remove(args[1]);
            db.run("UPDATE bots SET is_active=0 WHERE name=?", [args[1]]);
            emitLog('sys', `Bot ${args[1]} removed.`);
        }
        else if (cmd === '/say' && args.length >= 3) {
            const b = cluster.bots.get(args[1]);
            if(b) b.instance.chat(args.slice(2).join(' '));
        }
        else if (cmd === '/goto' && args.length >= 5) {
            const b = cluster.bots.get(args[1]);
            if(b) b.instance.pathfinder.setGoal(new goals.GoalNear(parseFloat(args[2]), parseFloat(args[3]), parseFloat(args[4]), 1));
        }
        else if (cmd === '/script' && args[1] === 'run' && args.length >= 3) {
            // Demo script inline execution
            const sampleScript = `DELAY 1000\nSAY Hello from Macro!\nLOOK 3.14 0\nMOVE forward 1000`;
            cluster.runMacro(args[2], sampleScript, emitLog);
        }
        else { emitLog('err', 'Unknown command or missing args.'); }
    });

    socket.on('request_inventory', (botName) => {
        const b = cluster.bots.get(botName);
        if(b && b.instance.inventory) {
            const items = b.instance.inventory.items().map(i => ({ name: i.name, count: i.count, slot: i.slot }));
            socket.emit('inventory_data', { bot: botName, items });
        }
    });

    // Finny UI AI Handler
    socket.on('ai_request', async (msg) => {
        try {
            const chatCompletion = await groq.chat.completions.create({
                messages: [
                    { role: 'system', content: 'You are Finny, the system administrator assistant for this Minecraft Bot cluster. Respond concisely.' },
                    { role: 'user', content: msg }
                ],
                model: 'llama-3.3-70b-versatile',
            });
            socket.emit('ai_response', chatCompletion.choices[0]?.message?.content);
        } catch(e) { socket.emit('ai_response', "Backend AI API Error."); }
    });
});

// ==========================================
// 8. AUTO-RECOVERY & GRACEFUL SHUTDOWN
// ==========================================
server.listen(PORT, () => {
    console.log(`[SYSTEM] Engine online on port ${PORT}`);
    // Auto-Recovery from DB
    setTimeout(() => {
        db.all("SELECT * FROM bots WHERE is_active=1", (err, rows) => {
            if(rows) rows.forEach(r => cluster.spawn({ name: r.name, host: r.host, port: r.port, version: r.version, auth_mode: r.auth_mode, proxy: r.proxy }, (type, msg) => console.log(`[RECOVERY] ${msg}`)));
        });
    }, 2000);
});

// OS Signal Traps
const shutdown = () => {
    console.log('\n[SYSTEM] SIGTERM received. Executing graceful shutdown...');
    Array.from(cluster.bots.values()).forEach(b => {
        b.instance.quit('Dyno Restarting - BRB');
    });
    db.close();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 5000);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

EOF

# Expose port and run the monolithic Node script
EXPOSE 3000
CMD ["node", "/app/bot.js"]
