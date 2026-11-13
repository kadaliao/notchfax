/**
 * Notchfax receipt for OpenCode: when an interactive TUI exits, Notchfax prints a receipt
 * for each top-level session that ran in it (see README.md next to this file).
 *
 * The plugin only records which sessions were active and starts a detached watcher
 * (notchfax_watch.py) that waits for this process to exit, so a receipt still prints
 * when the TUI is closed by a signal. notchfax_receipt.py does the billing and printing.
 * Turn off: NOTCHFAX_RECEIPT_DISABLED=1, or remove the entry from opencode.json.
 */
import type { Plugin } from "@opencode-ai/plugin"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdirSync, renameSync, writeFileSync, appendFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

// The two Python helpers live next to this file, wherever it was installed.
const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))
const STATE_DIR = join(homedir(), "Library", "Application Support", "Notchfax")
const LOG_PATH = join(homedir(), "Library", "Logs", "Notchfax", "opencode-receipt.log")

type ActiveSession = {
  at: number
  title?: string
  directory?: string
}

type ActiveFile = {
  pid: number
  directory: string
  started: number
  watcher: boolean
  sessions: Record<string, ActiveSession>
}

function disabled() {
  return ["1", "true", "yes", "on"].includes(String(process.env.NOTCHFAX_RECEIPT_DISABLED || "").toLowerCase())
}

function isInteractiveTui() {
  if (process.env.CI || disabled()) return false
  const args = process.argv.map((arg) => String(arg))
  if (args.includes("run") || args.includes("serve") || args.includes("generate")) return false
  if (args.some((arg) => /cli\/tui\/worker\.(js|ts)$/.test(arg))) return true
  return Boolean(process.stdin?.isTTY && process.stdout?.isTTY)
}

function logError(message: string) {
  try {
    mkdirSync(join(homedir(), "Library", "Logs", "Notchfax"), { recursive: true })
    appendFileSync(LOG_PATH, `[${new Date().toISOString()}] plugin: ${message}\n`)
  } catch {
    // Never let logging break the session.
  }
}

function writeActive(path: string, data: ActiveFile) {
  try {
    mkdirSync(STATE_DIR, { recursive: true })
    const tmp = `${path}.tmp`
    writeFileSync(tmp, JSON.stringify(data, null, 2))
    renameSync(tmp, path)
  } catch (error) {
    logError(`state write failed: ${String(error)}`)
  }
}

export const NotchfaxReceipt: Plugin = async ({ directory }) => {
  if (!isInteractiveTui()) return {}

  const key = createHash("sha1").update(`${process.pid}:${directory}`).digest("hex").slice(0, 10)
  const activePath = join(STATE_DIR, `active-${process.pid}-${key}.json`)
  const state: ActiveFile = {
    pid: process.pid,
    directory,
    started: Date.now(),
    watcher: false,
    sessions: {},
  }

  writeActive(activePath, state)

  const remember = (sessionID: string | undefined, info?: any) => {
    if (!sessionID) return
    if (info?.parentID) return
    state.sessions[sessionID] = {
      at: Date.now(),
      title: info?.title ?? state.sessions[sessionID]?.title,
      directory: info?.directory ?? state.sessions[sessionID]?.directory,
    }
    writeActive(activePath, state)
  }

  try {
    const child = spawn(
      "/usr/bin/python3",
      [
        join(PLUGIN_DIR, "notchfax_watch.py"),
        "--pid",
        String(process.pid),
        "--sessions",
        activePath,
        "--receipt",
        join(PLUGIN_DIR, "notchfax_receipt.py"),
      ],
      { detached: true, stdio: "ignore", env: process.env },
    )
    child.unref()
    state.watcher = true
    writeActive(activePath, state)
  } catch (error) {
    logError(`watcher spawn failed: ${String(error)}`)
  }

  return {
    event: async ({ event }) => {
      try {
        const properties: any = (event as any).properties ?? {}
        switch (event.type) {
          case "session.created":
          case "session.updated":
            remember(properties.sessionID ?? properties.info?.id, properties.info)
            break
          case "session.idle":
            remember(properties.sessionID)
            break
          case "message.updated":
            if (properties.info?.role === "assistant") {
              remember(properties.info.sessionID)
            }
            break
          case "session.deleted":
            if (properties.sessionID && state.sessions[properties.sessionID]) {
              delete state.sessions[properties.sessionID]
              writeActive(activePath, state)
            }
            break
        }
      } catch (error) {
        logError(`event handling failed: ${String(error)}`)
      }
    },
  }
}
