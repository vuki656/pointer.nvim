#!/usr/bin/env node
import { execFileSync } from "node:child_process"
import { readdirSync, statSync } from "node:fs"
import { createInterface } from "node:readline"
import { resolve } from "node:path"
import { homedir } from "node:os"

const TOOLS = [
    {
        name: "point",
        description:
            "Highlight lines in the user's Neovim and attach a comment shown above them, without editing the file. " +
            "Use it whenever you explain, review, or walk the user through code: point at each spot you are talking about " +
            "so they see it in their editor while reading your answer. Points stay until cleared; the user jumps between " +
            "them with ]a and [a. Call once per explanation with all points in reading order. Use kind 'warn' only for " +
            "problems, 'note' for everything else. Clear old points with the clear tool before starting an unrelated walkthrough.",
        inputSchema: {
            type: "object",
            properties: {
                points: {
                    type: "array",
                    minItems: 1,
                    items: {
                        type: "object",
                        properties: {
                            file: { type: "string", description: "Absolute path to the file. Relative paths resolve against the directory Claude was started in." },
                            line: { type: "integer", minimum: 1, description: "First line (1-based)" },
                            end_line: { type: "integer", minimum: 1, description: "Last line, defaults to line" },
                            text: { type: "string", description: "Short comment shown above the lines. One or two sentences." },
                            kind: { type: "string", enum: ["note", "warn"], description: "Defaults to note" },
                        },
                        required: ["file", "line", "text"],
                    },
                },
                focus: {
                    type: "boolean",
                    description: "Open the first point in the editor and move the cursor there. Defaults to true.",
                },
            },
            required: ["points"],
        },
    },
    {
        name: "clear",
        description: "Remove every point from the user's Neovim. Use before an unrelated walkthrough or when the user says they are done.",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "where",
        description:
            "Get what the user is looking at in Neovim: current file, cursor line, and their last visual selection with its text. " +
            "Use when the user says 'this', 'here', 'what is this' or otherwise refers to code without naming it.",
        inputSchema: { type: "object", properties: {} },
    },
]

let socket = null

function tmux(args) {
    try {
        return execFileSync("tmux", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim()
    } catch {
        return null
    }
}

function nvimExpr(sock, expr, timeout = 10000) {
    try {
        return execFileSync("nvim", ["--server", sock, "--remote-expr", expr], {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
            maxBuffer: 16 * 1024 * 1024,
            timeout,
            killSignal: "SIGKILL",
        })
    } catch (error) {
        const stderr = (error.stderr || "").trim()
        const timedOut = error.code === "ETIMEDOUT" || error.signal === "SIGKILL"
        const wrapped = new Error(timedOut ? `nvim at ${sock} did not respond (busy or waiting at a prompt)` : stderr || error.message)

        wrapped.transport = timedOut || /E247|E5\d+: |ECONNREFUSED|ENOENT/.test(stderr) || stderr === ""

        throw wrapped
    }
}

function alive(sock) {
    try {
        nvimExpr(sock, "1", 1500)

        return true
    } catch {
        return false
    }
}

function owned(path) {
    const stat = statSync(path)

    return process.getuid === undefined || stat.uid === process.getuid()
}

function listSockets() {
    const dirs = process.env.XDG_RUNTIME_DIR ? [process.env.XDG_RUNTIME_DIR] : [`/tmp/nvim.${process.env.USER}`]
    const found = []

    for (const dir of dirs) {
        let entries = []

        try {
            if (!owned(dir)) {
                continue
            }

            entries = readdirSync(dir)
        } catch {
            continue
        }

        for (const entry of entries) {
            const path = `${dir}/${entry}`

            try {
                const stat = statSync(path)

                if (stat.isSocket() && owned(path) && /^nvim\.\d+\.\d+$/.test(entry)) {
                    found.push({ path, mtime: stat.mtimeMs })
                } else if (stat.isDirectory() && owned(path)) {
                    for (const inner of readdirSync(path)) {
                        const innerPath = `${path}/${inner}`

                        if (/^nvim\.\d+\.\d+$/.test(inner) && owned(innerPath)) {
                            found.push({ path: innerPath, mtime: statSync(innerPath).mtimeMs })
                        }
                    }
                }
            } catch {}
        }
    }

    return found.sort((a, b) => b.mtime - a.mtime).map((entry) => entry.path)
}

function paneLocation(pane) {
    if (!pane) {
        return null
    }

    const out = tmux(["display", "-p", "-t", pane, "#{session_id} #{window_id}"])

    if (!out) {
        return null
    }

    const [session, window] = out.split(" ")

    return { session, window }
}

function discover() {
    if (process.env.NVIM) {
        return process.env.NVIM
    }

    const sockets = listSockets().filter(alive)

    if (sockets.length === 0) {
        throw new Error("no running nvim found")
    }

    const mine = paneLocation(process.env.TMUX_PANE)

    if (!mine) {
        if (sockets.length > 1) {
            throw new Error(`several nvims running and no tmux context to pick one; set NVIM to one of: ${sockets.join(", ")}`)
        }

        return sockets[0]
    }

    let sameSession = null

    for (const sock of sockets) {
        let pane = null

        try {
            pane = nvimExpr(sock, "$TMUX_PANE", 1500).trim()
        } catch {
            continue
        }

        const location = paneLocation(pane)

        if (!location) {
            continue
        }

        if (location.window === mine.window) {
            return sock
        }

        if (location.session === mine.session && !sameSession) {
            sameSession = sock
        }
    }

    if (sameSession) {
        return sameSession
    }

    if (sockets.length === 1) {
        return sockets[0]
    }

    throw new Error(`no nvim in this tmux session; set NVIM to one of: ${sockets.join(", ")}`)
}

function call(method, params) {
    const payload = JSON.stringify({ method, params }).replace(/'/g, "''")
    const expr = `v:lua.require('pointer').rpc('${payload}')`

    if (Buffer.byteLength(expr) > 120 * 1024) {
        throw new Error("payload too large, send fewer points per call")
    }

    const run = () => {
        if (!socket) {
            socket = discover()
        }

        return nvimExpr(socket, expr)
    }

    let raw

    try {
        raw = run()
    } catch (error) {
        if (!error.transport) {
            throw error
        }

        socket = null
        raw = run()
    }

    let result

    try {
        result = JSON.parse(raw)
    } catch {
        throw new Error(`unexpected reply from nvim, is pointer.nvim loaded there? ${raw.trim().slice(0, 200)}`)
    }

    if (result && result.error) {
        throw new Error(result.error)
    }

    return result
}

function handleTool(name, args) {
    if (name === "point") {
        if (!Array.isArray(args.points) || args.points.length === 0) {
            throw new Error("points must be a non-empty array")
        }

        const points = args.points.map((point) => ({
            ...point,
            file: resolve(String(point.file || "").replace(/^~(?=\/|$)/, homedir())),
        }))

        const result = call("point", { points, focus: args.focus !== false })

        return `Placed ${result.ids.length} point(s).`
    }

    if (name === "clear") {
        call("clear", {})

        return "Cleared."
    }

    if (name === "where") {
        return JSON.stringify(call("where", {}), null, 2)
    }

    throw new Error(`unknown tool ${name}`)
}

function respond(id, result) {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n")
}

function fail(id, code, message) {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }) + "\n")
}

function handle(message) {
    const { id, method, params } = message

    if (method === "initialize") {
        respond(id, {
            protocolVersion: params?.protocolVersion || "2025-06-18",
            capabilities: { tools: {} },
            serverInfo: { name: "pointer", version: "0.1.0" },
        })

        return
    }

    if (method === "ping") {
        respond(id, {})

        return
    }

    if (method === "tools/list") {
        respond(id, { tools: TOOLS })

        return
    }

    if (method === "tools/call") {
        try {
            const text = handleTool(params.name, params.arguments || {})

            respond(id, { content: [{ type: "text", text }] })
        } catch (error) {
            respond(id, { content: [{ type: "text", text: `pointer: ${error.message}` }], isError: true })
        }

        return
    }

    if (id !== undefined) {
        fail(id, -32601, `method not found: ${method}`)
    }
}

const reader = createInterface({ input: process.stdin, terminal: false })

reader.on("line", (line) => {
    if (!line.trim()) {
        return
    }

    let message

    try {
        message = JSON.parse(line)
    } catch {
        fail(null, -32700, "parse error")

        return
    }

    if (message === null || typeof message !== "object" || Array.isArray(message)) {
        fail(null, -32600, "invalid request")

        return
    }

    try {
        handle(message)
    } catch (error) {
        fail(message.id ?? null, -32603, error.message)
    }
})

reader.on("close", () => process.exit(0))
