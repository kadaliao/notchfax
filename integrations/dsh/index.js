/**
 * Notchfax receipt hook for the DeepSeek Harness desktop app.
 *
 * A session "ends" two ways here, and both print (see README.md):
 *   - archive: the registry's archived-session set is polled; a newly archived
 *     id bills right away (archiving does not dispose the agent);
 *   - quit: the agent teardown described below.
 *
 * There is no SessionEnd seam in this DSH build, so the quit receipt rides the
 * session-end point the Host actually owns: an asynchronous `ctx.effect`
 * disposer on the agent's scoped context, registered from `agent/created`.
 * Cordis awaits async disposers, and an agent's teardown runs after the loop is
 * quiescent but before the session leaves the store — so the log can still be
 * flushed there. On app quit the whole tree is disposed under a 5 s cap, which
 * this hook fits easily: it flushes, spawns a detached helper, and returns.
 *
 * The helper (receipt.py) does the slow part — reading the session log,
 * pricing tokens, calling Notchfax — in its own process, so the hook never
 * delays shutdown. Hook failures are swallowed and written to
 * ~/Library/Logs/Notchfax/dsh-receipt.log.
 *
 * Only root, human-started sessions in the Desktop host produce a receipt:
 *   - subagent / forked child sessions are skipped (origin, parentSession,
 *     delegationDepth);
 *   - sessions in a bot workspace are skipped (cwd);
 *   - other host processes (CLI, ACP, headless) never mount this profile row,
 *     and the desktop-process check keeps a stray `dsh web` from printing.
 *
 * @module @local/dsh-notchfax-receipt
 */

import { spawn } from 'node:child_process';
import { appendFileSync, mkdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export const name = 'notchfax-receipt';

/** No Host service is required; the agent registry is only used to catch agents
 *  that were already live when this row hot-mounted. */
export const inject = ['agents', 'sessions'];

// receipt.py sits next to this file, wherever the plugin was installed.
const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url));
const SCRIPT = join(PLUGIN_DIR, 'receipt.py');
const LOG_PATH = join(homedir(), 'Library', 'Logs', 'Notchfax', 'dsh-receipt.log');
const DEFAULT_PYTHON = '/usr/bin/python3';
const DEFAULT_BOTS_DIRS = ['~/Bots', '~/.dsh/Bots', '~/.dsh/bots'];

function log(line) {
  try {
    mkdirSync(dirname(LOG_PATH), { recursive: true });
    appendFileSync(LOG_PATH, `${new Date().toISOString()} [plugin] ${line}\n`);
  } catch {
    // Logging must never throw into a shutdown path.
  }
}

function expandHome(value) {
  return value.startsWith('~/') ? join(homedir(), value.slice(2)) : value;
}

function settingsOf(config) {
  const raw = config && typeof config === 'object' ? config : {};
  return {
    enabled: raw.enabled !== false,
    pollMs: Number.isFinite(raw.pollMs) && raw.pollMs >= 250 ? raw.pollMs : 1500,
    python: typeof raw.python === 'string' && raw.python ? raw.python : DEFAULT_PYTHON,
    botsDirs: Array.isArray(raw.botsDirs) && raw.botsDirs.length
      ? raw.botsDirs.map(expandHome)
      : DEFAULT_BOTS_DIRS.map(expandHome),
  };
}

/** True in the Desktop host process (Electron main or its Node-side runtime). */
function isDesktopHost() {
  if (process.versions && process.versions.electron) return true;
  const hints = [process.execPath, ...(Array.isArray(process.argv) ? process.argv.slice(0, 2) : [])];
  return hints.some((hint) => typeof hint === 'string' && /DeepSeek Harness\.app|dsh-desktop|app\.asar/i.test(hint));
}

function isBotWorkspace(cwd, botsDirs) {
  const target = resolve(cwd).toLowerCase();
  return botsDirs.some((dir) => {
    const base = resolve(dir).toLowerCase().replace(/\/+$/, '');
    return target === base || target.startsWith(base + sep);
  });
}

function inChildSession(header) {
  return Boolean(
    header.origin === 'subagent'
    || header.parentSession !== undefined
    || (typeof header.delegationDepth === 'number' && header.delegationDepth > 0),
  );
}

function spawnReceipt(settings, header, extraArgs = []) {
  const args = [settings.python, SCRIPT, '--hook', '--session', header.id, '--cwd', header.cwd || '', ...extraArgs];
  const env = {
    ...process.env,
    PATH: ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', process.env.PATH || '']
      .filter(Boolean)
      .join(':'),
  };
  try {
    const child = spawn(args[0], args.slice(1), {
      cwd: homedir(),
      detached: true,
      stdio: 'ignore',
      env,
    });
    child.on('error', (error) => log(`spawn error for ${header.id}: ${error?.stack || error}`));
    child.unref();
    log(`spawned receipt for ${header.id} (${header.cwd || 'no cwd'})`);
  } catch (error) {
    log(`spawn threw for ${header.id}: ${error?.stack || error}`);
  }
}


const ARMS_KEY = Symbol.for('dsh.notchfax-receipt.arms');

/** Process-wide arm table shared by every plugin generation loaded in this process. */
function armRegistry() {
  const store = globalThis;
  if (!(store[ARMS_KEY] instanceof Map)) store[ARMS_KEY] = new Map();
  return store[ARMS_KEY];
}

/**
 * Read the live profile patch at firing time. Agent-scope arms outlive the
 * plugin row, so this is what makes "disable" mean off even for agents that
 * were armed before the row was disabled: it never depends on unload order.
 */
function rowEnabled() {
  try {
    const file = join(homedir(), '.dsh', 'profiles', 'desktop', 'cordis.patch.yml');
    const text = readFileSync(file, 'utf8');
    const at = text.indexOf('id: notchfax-receipt');
    if (at < 0) return false;
    const block = text.slice(at, at + 300);
    const match = block.match(/enabled:\s*(true|false)/);
    return match ? match[1] === 'true' : true;
  } catch {
    return true;
  }
}

/** Durability checkpoint with a bound: shutdown must never wait on the writer. */
async function flushBounded(ctx, session, id) {
  try {
    await Promise.race([
      ctx.sessions.flush(session),
      new Promise((resolve) => setTimeout(resolve, 2000)),
    ]);
  } catch (error) {
    log(`flush failed for ${id}: ${error?.message || error}`);
  }
}

/** A candidate is a root, human-started session with a real workspace. */
function candidate(header, settings) {
  if (!header || typeof header.id !== 'string' || !header.id) return false;
  if (inChildSession(header)) return false;
  if (!header.cwd) return false;
  if (isBotWorkspace(header.cwd, settings.botsDirs)) return false;
  return true;
}

export function apply(ctx, config) {
  const settings = settingsOf(config);
  if (!settings.enabled) return;
  if (!isDesktopHost()) {
    log(`skip mount: not the Desktop host (execPath=${process.execPath}, electron=${process.versions?.electron || '-'})`);
    return;
  }
  log(`mounted (execPath=${process.execPath}, electron=${process.versions?.electron || '-'}, pid=${process.pid})`);

  const installed = new WeakSet();
  ctx.effect(() => () => log('unloaded'));

  // ---- archive trigger -----------------------------------------------------
  // Archiving a session does not dispose its agent, so the teardown arm never
  // fires there. The registry exposes the durable archive set (`workspace/
  // session-stop` only fires when the UI also stops running work), so poll it
  // and bill the segment the moment a session enters the set.
  /** @returns {string[] | null} null while the registry is not readable yet. */
  const knownArchived = () => {
    try {
      const registry = typeof ctx.get === 'function' ? ctx.get('workspaceRegistry') : undefined;
      if (!registry || !Array.isArray(registry.archivedSessionIds)) return null;
      return Array.from(registry.archivedSessionIds);
    } catch (error) {
      log(`archive set unreadable: ${error?.message || error}`);
      return null;
    }
  };
  const seeded = knownArchived();
  const archived = new Set(seeded ?? []);
  // Only diff after one successful read: otherwise every pre-existing archived
  // session would look newly archived and print on the first tick.
  let primed = seeded !== null;

  const onArchived = async (sessionId) => {
    try {
      // Retire the quit-time arm for this session: it stays registered on the
      // agent scope, but a missing table entry makes it a no-op.
      armRegistry().delete(sessionId);
      const session = typeof ctx.sessions?.get === 'function' ? ctx.sessions.get(sessionId) : undefined;
      const header = session?.header;
      if (header && !candidate(header, settings)) {
        log(`archive skip ${sessionId}: child or bot session`);
        return;
      }
      if (session) await flushBounded(ctx, session, sessionId);
      const extra = settings.botsDirs.flatMap((dir) => ['--bots-dir', dir]);
      extra.push('--archive');
      const target = header
        ? { ...header, id: sessionId }
        : { id: sessionId, cwd: '' };
      spawnReceipt(settings, target, extra);
    } catch (error) {
      log(`archive handling failed for ${sessionId}: ${error?.stack || error}`);
    }
  };

  ctx.effect(() => {
    const timer = setInterval(() => {
      const ids = knownArchived();
      if (ids === null) return;
      if (!primed) {
        for (const id of ids) archived.add(id);
        primed = true;
        log(`archive set primed with ${ids.length} archived session(s)`);
        return;
      }
      const current = new Set(ids);
      for (const id of current) {
        if (archived.has(id)) continue;
        archived.add(id);
        void onArchived(id);
      }
      // Unarchiving removes the id again, so a later re-archive bills again.
      for (const id of archived) if (!current.has(id)) archived.delete(id);
    }, settings.pollMs);
    return () => clearInterval(timer);
  });
  log(`archive watcher on (every ${settings.pollMs} ms; ${archived.size} already archived)`);

  const install = (agent) => {
    const session = agent?.session;
    const header = session?.header;
    if (!header || installed.has(agent)) return;
    installed.add(agent);
    if (typeof ctx.agents?.get === 'function' && !ctx.agents.get(agent.id)) return;
    if (!candidate(header, settings)) {
      log(`skip ${header.id}: ${header.origin || 'root'}${header.parentSession ? ', parent' : ''}`);
      return;
    }
    try {
      // Async disposer: awaited during agent teardown, after quiescence and
      // before session detachment, so a flush here is still legal.
      const arm = async () => {
        await flushBounded(ctx, session, header.id);
        const arms = armRegistry();
        if (arms.get(header.id) !== arm) return; // a newer generation owns this session
        arms.delete(header.id);
        if (!rowEnabled()) {
          log(`skipped ${header.id}: disabled in the profile patch`);
          return;
        }
        if (candidate(session.header, settings)) spawnReceipt(settings, session.header);
      };
      armRegistry().set(header.id, arm);
      agent.ctx.effect(() => arm);
      log(`armed ${header.id}`);
    } catch (error) {
      log(`arm failed for ${header.id}: ${error?.stack || error}`);
    }
  };

  ctx.on('agent/created', ({ agent }) => install(agent));

  // Hot-mounting into a running app: agents that already exist get armed here.
  try {
    for (const agent of ctx.agents.list()) install(agent);
  } catch (error) {
    log(`listing live agents failed: ${error?.stack || error}`);
  }
}
