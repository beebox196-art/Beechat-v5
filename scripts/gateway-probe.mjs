import { WebSocket } from 'ws';
import fs from 'fs';

const config = JSON.parse(fs.readFileSync('/Users/openclaw/.openclaw/openclaw.json', 'utf8'));
const token = config.gateway?.auth?.token || '';
const url = `ws://127.0.0.1:18789?token=${token}`;

const events = [];

const ws = new WebSocket(url);

ws.on('open', () => {
    console.log('--- Connected to gateway ---');
});

ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    events.push(msg);
    const type = msg.type || 'unknown';
    const event = msg.event || '';
    console.log(`\n--- Received: type=${type} event=${event} ---`);
    console.log(JSON.stringify(msg, null, 2).slice(0, 3000));
    
    if (event === 'connect.challenge') {
        console.log('\n[Got challenge - sending connect request]');
        const connectReq = {
            type: 'req',
            id: 'probe-1',
            method: 'connect',
            params: {
                minProtocol: 3,
                maxProtocol: 3,
                client: { id: 'beechat-probe', version: '0.1.0', platform: 'macos', mode: 'operator' },
                role: 'operator',
                scopes: ['operator.read', 'operator.write'],
                auth: { token: token }
            }
        };
        ws.send(JSON.stringify(connectReq));
    }
    
    if (type === 'res' && msg.id === 'probe-1') {
        console.log('\n[Got connect response - requesting sessions.list]');
        const sessionsReq = {
            type: 'req',
            id: 'probe-2',
            method: 'sessions.list',
            params: {}
        };
        ws.send(JSON.stringify(sessionsReq));
    }
    
    if (type === 'res' && msg.id === 'probe-2') {
        console.log('\n[Got sessions.list - requesting chat.history for first session]');
        const sessions = msg.payload?.sessions || msg.payload?.ok?.sessions || [];
        if (sessions.length > 0) {
            const sessionKey = sessions[0].key;
            console.log(`Requesting chat.history for: ${sessionKey}`);
            const historyReq = {
                type: 'req',
                id: 'probe-3',
                method: 'chat.history',
                params: { sessionKey: sessionKey, limit: 5 }
            };
            ws.send(JSON.stringify(historyReq));
        } else {
            console.log('No sessions found');
        }
    }
    
    if (type === 'res' && msg.id === 'probe-3') {
        console.log('\n=== Captured enough data, closing ===');
        ws.close();
    }
});

ws.on('error', (err) => {
    console.error('WebSocket error:', err.message);
});

ws.on('close', (code, reason) => {
    console.log(`\n--- Connection closed: code=${code} ---`);
    console.log(`\n=== SUMMARY: Captured ${events.length} events ===`);
    const types = new Set(events.map(e => e.type));
    const eventNames = new Set(events.map(e => e.event).filter(Boolean));
    console.log('Types:', [...types].join(', '));
    console.log('Events:', [...eventNames].join(', '));
    
    fs.writeFileSync('/Users/openclaw/projects/BeeChat-v5/Docs/History/GATEWAY-PROBE-CAPTURE.json', JSON.stringify(events, null, 2));
    console.log('\nFull capture written to Docs/History/GATEWAY-PROBE-CAPTURE.json');
});

setTimeout(() => {
    console.log('\n=== Timeout - closing ===');
    ws.close();
}, 15000);