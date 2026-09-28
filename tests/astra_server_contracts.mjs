// Independent tests against the actual pinned upstream server, not a reimplementation.
// Usage: node tests/astra_server_contracts.mjs PATH_TO_BUILT_UPSTREAM
import assert from 'node:assert/strict';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const root = path.resolve(process.argv[2] || '../../work/upstream-api-server');
const load = name => import(pathToFileURL(path.join(root, 'dist', name)).href);
const {default: Client} = await load('Client.js');
const {default: Lobby, Lobbies} = await load('Lobby.js');
const {actionHandlers: A} = await load('actionHandlers.js');
let passed = 0;
function test(name, fn) { fn(); passed++; console.log(`PASS ${name}`); Lobbies.clear(); }
function pair() {
  const humanMessages = [], aiMessages = [];
  const human = new Client({}, msg => humanMessages.push(msg), () => {}, '127.0.0.1');
  const ai = new Client({}, msg => aiMessages.push(msg), () => {}, '127.0.0.1');
  human.username = 'LOCAL HUMAN'; ai.username = 'BALATRO AI';
  const lobby = new Lobby(human, 'attrition');
  lobby.join(ai);
  assert.equal(lobby.guest, ai);
  humanMessages.length = aiMessages.length = 0;
  return {human, ai, lobby, humanMessages, aiMessages};
}
const has = (messages, name) => messages.some(m => m.action === name);
function hand(client, score, handsLeft) { A.playHand({score: String(score), handsLeft}, client); }
test('guest cannot start match', () => {
  const p = pair(); A.startGame(p.ai);
  assert.equal(p.lobby.isInGame, false); assert.equal(has(p.humanMessages, 'startGame'), false);
});
test('host starts real attrition with original generated seed', () => {
  const p = pair(); A.startGame(p.human);
  assert.equal(p.lobby.isInGame, true);
  const h = p.humanMessages.find(m => m.action === 'startGame');
  const a = p.aiMessages.find(m => m.action === 'startGame');
  assert.equal(typeof h.seed, 'string'); assert.ok(h.seed.length > 0); assert.equal(h.seed, a.seed);
  assert.equal(p.human.lives, p.ai.lives); assert.ok(p.ai.lives > 0);
});
test('different seeds follows upstream omitted seed path', () => {
  const p = pair(); p.lobby.options.different_seeds = true; A.startGame(p.human);
  assert.equal(p.humanMessages.find(m => m.action === 'startGame').seed, undefined);
});
test('first-ready waits and second-ready starts original blind', () => {
  const p = pair(); A.readyBlind(p.ai);
  assert.equal(has(p.aiMessages, 'speedrun'), true); assert.equal(has(p.aiMessages, 'startBlind'), false);
  A.readyBlind(p.human);
  assert.equal(p.humanMessages.find(m => m.action === 'startBlind').firstPlayer, 'guest');
  assert.equal(p.ai.isReady, false); assert.equal(p.human.isReady, false);
});
test('leader exhausted does not prematurely defeat trailing player', () => {
  const p = pair(); hand(p.ai, 100, 0); hand(p.human, 50, 2);
  assert.equal(has(p.humanMessages, 'endPvP'), false); assert.equal(p.human.lives, 5);
});
test('AI PvP win deducts human life through upstream', () => {
  const p = pair(); hand(p.ai, 100, 1); hand(p.human, 50, 0);
  assert.equal(p.human.lives, 4); assert.equal(p.ai.lives, 5);
  assert.equal(p.humanMessages.find(m => m.action === 'endPvP').lost, true);
  assert.equal(p.aiMessages.find(m => m.action === 'endPvP').lost, false);
});
test('human PvP win deducts AI life through upstream', () => {
  const p = pair(); hand(p.human, 100, 1); hand(p.ai, 50, 0);
  assert.equal(p.ai.lives, 4); assert.equal(p.human.lives, 5);
  assert.equal(p.aiMessages.find(m => m.action === 'endPvP').lost, true);
});
test('equal exhausted scores cost no life', () => {
  const p = pair(); hand(p.human, 100, 0); hand(p.ai, 100, 0);
  assert.equal(p.human.lives, 5); assert.equal(p.ai.lives, 5);
  assert.equal(p.aiMessages.find(m => m.action === 'endPvP').lost, false);
});
for (const loserRole of ['human', 'ai']) test(`terminal ${loserRole} loss sends win/lose without endPvP`, () => {
  const p = pair(), loser = p[loserRole], winner = p[loserRole === 'human' ? 'ai' : 'human'];
  loser.lives = 1; hand(winner, 100, 1); hand(loser, 50, 0);
  const lost = loserRole === 'human' ? p.humanMessages : p.aiMessages;
  const won = loserRole === 'human' ? p.aiMessages : p.humanMessages;
  assert.equal(loser.lives, 0); assert.ok(has(lost, 'loseGame')); assert.ok(has(won, 'winGame'));
  assert.equal(has(lost, 'endPvP'), false); assert.equal(has(won, 'endPvP'), false);
});
test('round and timer blockers independent, each once per round', () => {
  const p = pair(); p.ai.loseLife('round'); p.ai.loseLife('round');
  assert.equal(p.ai.lives, 4); p.ai.loseLife('timer'); p.ai.loseLife('timer');
  assert.equal(p.ai.lives, 3); p.ai.resetBlocker(); p.ai.loseLife('round'); assert.equal(p.ai.lives, 2);
});
test('same IP does not alias the two actual Client states', () => {
  const p = pair(); assert.notEqual(p.ai.id, p.human.id); assert.notEqual(p.ai.reconnectToken, p.human.reconnectToken);
  p.ai.lives = 2; p.ai.handsLeft = 0; assert.equal(p.human.lives, 5); assert.equal(p.human.handsLeft, 4);
});
test('hide-score option suppresses opponent score before own play', () => {
  const p = pair(); p.lobby.options.hide_score_until_played = true;
  hand(p.ai, 999, 3);
  const frame = p.humanMessages.filter(m => m.action === 'enemyInfo').at(-1);
  assert.equal(frame.noScore, true); assert.equal(frame.score, null);
});
console.log(`PASS ${passed} upstream server contracts; no game runtime or listener started`);
