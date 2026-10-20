import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdir, mkdtemp, open, realpath, rename, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";

const revisionPattern = /^[a-f0-9]{40}$/;

export function run(command, args, { cwd, env, signal, timeout = 30_000, onOutput, allowedCodes = [0] } = {}) {
    signal?.throwIfAborted();
    return new Promise((resolve, reject) => {
        const child = spawn(command, args, {
            cwd, env: { ...process.env, GIT_TERMINAL_PROMPT: "0", ...env },
            detached: true, stdio: ["ignore", "pipe", "pipe"],
        });
        let stdout = "";
        let stderr = "";
        let stopped;
        let forceTimer;
        const stop = (reason) => {
            stopped = reason;
            if (!child.pid) return;
            const kill = (signalName) => {
                try {
                    process.kill(-child.pid, signalName);
                } catch (error) {
                    if (error.code !== "ESRCH") reject(error);
                }
            };
            kill("SIGTERM");
            forceTimer = setTimeout(() => kill("SIGKILL"), 1000);
        };
        const abort = () => stop("Build interrupted; the existing app was not replaced.");
        const timer = setTimeout(() => stop(`${command} timed out.`), timeout);
        signal?.addEventListener("abort", abort, { once: true });
        const cleanup = () => {
            clearTimeout(timer);
            clearTimeout(forceTimer);
            signal?.removeEventListener("abort", abort);
        };
        child.stdout.on("data", (chunk) => {
            stdout = (stdout + chunk).slice(-128_000);
            onOutput?.(chunk.toString());
        });
        child.stderr.on("data", (chunk) => {
            stderr = (stderr + chunk).slice(-128_000);
            onOutput?.(chunk.toString());
        });
        child.once("error", (error) => { cleanup(); reject(error); });
        child.once("close", (code) => {
            cleanup();
            if (stopped || !allowedCodes.includes(code)) {
                reject(new Error(stopped || `${command} exited ${code}:\n${stderr || stdout}`));
            } else {
                resolve({ stdout: stdout.trim(), stderr: stderr.trim(), code });
            }
        });
    });
}

async function exists(path) {
    try {
        return await lstat(path);
    } catch (error) {
        if (error.code === "ENOENT") return null;
        throw error;
    }
}

export function nextBuildNumber(current) {
    if (current === undefined) return "1";
    if (!/^[1-9][0-9]*(\.[0-9]+){0,2}$/.test(current)) {
        throw new Error(`Cannot increment installed build number: ${current}`);
    }
    return (BigInt(current.split(".")[0]) + 1n).toString();
}

export async function createManager(repoPath, {
    appPath = join(homedir(), "Applications", "Notess.app"),
    storagePath = join(process.env.COPILOT_HOME || join(homedir(), ".copilot"),
        "extensions", "notess-manager", "artifacts"),
} = {}) {
    if (process.platform !== "darwin") throw new Error("The Notess manager requires macOS.");
    if (!isAbsolute(repoPath)) throw new Error("Choose an absolute repository path.");
    const repository = await realpath(repoPath);
    const { stdout: root } = await run("git", ["-C", repository, "rev-parse", "--show-toplevel"]);
    if (root !== repository) throw new Error("Choose the repository root, not a subfolder.");
    return new AppManager(repository, appPath, storagePath);
}

class AppManager {
    constructor(repoPath, appPath, storagePath) {
        this.repoPath = repoPath;
        this.appPath = appPath;
        this.lockPath = join(storagePath,
            `${createHash("sha256").update(appPath).digest("hex").slice(0, 16)}.lock`);
        this.phase = "idle";
        this.installed = null;
        this.latestRevision = null;
        this.checkedAt = null;
        this.error = null;
        this.checkError = null;
        this.logs = "";
        this.running = false;
        this.locked = false;
        this.job = null;
        this.refreshTask = null;
    }

    snapshot() {
        return {
            repoPath: this.repoPath, appPath: this.appPath, phase: this.phase,
            lockPath: this.lockPath,
            installed: this.installed, latestRevision: this.latestRevision,
            checkedAt: this.checkedAt, running: this.running, locked: this.locked,
            busy: this.job !== null, error: this.error, checkError: this.checkError,
            updateAvailable: this.latestRevision !== null &&
                this.installed?.revision !== this.latestRevision,
            logs: this.logs,
        };
    }

    async readInstalled(appPath = this.appPath) {
        const stat = await exists(appPath);
        if (!stat) return null;
        if (!stat.isDirectory() || stat.isSymbolicLink()) {
            throw new Error(`Refusing to replace a non-directory or symlink: ${appPath}`);
        }
        const { stdout } = await run("/usr/bin/plutil",
            ["-convert", "json", "-o", "-", join(appPath, "Contents", "Info.plist")]);
        const info = JSON.parse(stdout);
        if (info.CFBundleIdentifier !== "com.michalmar.notess" ||
            typeof info.CFBundleVersion !== "string" ||
            typeof info.CFBundleShortVersionString !== "string") {
            throw new Error(`The app at ${appPath} is not a valid Notess bundle.`);
        }
        if (info.NotessSourceRevision !== undefined && !revisionPattern.test(info.NotessSourceRevision)) {
            throw new Error("The installed source revision is invalid.");
        }
        return {
            version: info.CFBundleShortVersionString,
            build: info.CFBundleVersion,
            revision: info.NotessSourceRevision ?? null,
        };
    }

    async isRunning() {
        const executable = join(this.appPath, "Contents", "MacOS", "Notess")
            .replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const { code } = await run("/usr/bin/pgrep",
            ["-u", String(process.getuid()), "-f", `^${executable}([[:space:]]|$)`],
            { allowedCodes: [0, 1] });
        return code === 0;
    }

    async refresh(force = false) {
        if (this.job) return this.snapshot();
        if (this.refreshTask) {
            const state = await this.refreshTask;
            return force ? this.refresh(true) : state;
        }
        this.refreshTask = (async () => {
            try {
                this.installed = await this.readInstalled();
                this.running = await this.isRunning();
                this.locked = (await exists(this.lockPath)) !== null;
                if (force || !this.checkedAt || Date.now() - Date.parse(this.checkedAt) >= 60_000) {
                    this.phase = "checking";
                    const { stdout } = await run("git",
                        ["-C", this.repoPath, "ls-remote", "--exit-code", "origin", "refs/heads/main"],
                        { timeout: 20_000 });
                    const revision = stdout.split(/\s+/)[0];
                    if (!revisionPattern.test(revision)) throw new Error("origin/main returned an invalid revision.");
                    this.latestRevision = revision;
                    this.checkedAt = new Date().toISOString();
                }
                this.checkError = null;
            } catch (error) {
                this.checkError = error.message;
            } finally {
                this.phase = "idle";
            }
            return this.snapshot();
        })();
        try {
            return await this.refreshTask;
        } finally {
            this.refreshTask = null;
        }
    }

    async startBuild() {
        if (this.job) throw new Error("A build is already in progress.");
        const state = await this.refresh(true);
        if (state.checkError) throw new Error(state.checkError);
        if (state.running) throw new Error("Quit Notess before building and installing an update.");
        if (!state.updateAvailable) throw new Error("The current main revision is already installed.");
        const buildNumber = nextBuildNumber(this.installed?.build);
        await mkdir(dirname(this.lockPath), { recursive: true });
        let lock;
        try {
            lock = await open(this.lockPath, "wx", 0o600);
        } catch (error) {
            if (error.code === "EEXIST") {
                throw new Error(`Another build holds ${this.lockPath}. If it was interrupted, remove that lock before retrying.`);
            }
            throw error;
        }
        await lock.close();
        this.locked = true;
        this.error = null;
        this.logs = "";
        this.phase = "fetching";
        this.abortController = new AbortController();
        const revision = this.latestRevision;
        this.job = this.build(revision, buildNumber, this.abortController.signal)
            .catch((error) => { this.error = error.message; })
            .finally(async () => {
                try {
                    await rm(this.lockPath);
                    this.locked = false;
                } catch (error) {
                    this.error = `${this.error || "Build finished."}\nCannot release build lock: ${error.message}`;
                }
                this.phase = "idle";
                this.job = null;
            });
        return this.snapshot();
    }

    async build(revision, buildNumber, signal) {
        const temporary = await mkdtemp(join(tmpdir(), "notess-manager-"));
        const source = join(temporary, "source");
        const output = join(temporary, "output");
        const command = (program, args, options = {}) => run(program, args, {
            signal, onOutput: (text) => { this.logs = (this.logs + text).slice(-40_000); },
            ...options,
        });
        try {
            await command("git", ["-C", this.repoPath, "fetch", "--no-tags",
                "--no-write-fetch-head", "origin", revision], { timeout: 60_000 });
            await mkdir(source);
            const archive = join(temporary, "source.tar");
            await command("git", ["-C", this.repoPath, "archive", "--format=tar", `--output=${archive}`, revision]);
            await command("/usr/bin/tar", ["-xf", archive, "-C", source]);
            await command("/usr/bin/plutil", ["-replace", "NotessSourceRevision", "-string", revision,
                join(source, "Support", "Info.plist")]);
            this.phase = "building";
            await command("/bin/bash", [join(source, "scripts", "build-app.sh"), "release"], {
                cwd: source, timeout: 600_000,
                env: {
                    OUTPUT_DIR: output, BUILD_NUMBER: buildNumber, CODESIGN_IDENTITY: "-",
                    BUILD_ARCH: process.arch === "x64" ? "x86_64" : "arm64",
                },
            });
            const builtApp = join(output, "Notess.app");
            await command("/usr/bin/codesign", ["--verify", "--strict", builtApp]);
            const built = await this.readInstalled(builtApp);
            if (built?.revision !== revision || built.build !== buildNumber) {
                throw new Error("The built app does not match the requested source revision and build number.");
            }
            this.phase = "installing";
            await this.install(builtApp, command, signal);
            this.installed = await this.readInstalled();
            this.logs += `\nInstalled build ${buildNumber} from ${revision}.\n`;
        } finally {
            await rm(temporary, { recursive: true, force: true });
        }
    }

    async install(builtApp, command, signal) {
        await mkdir(dirname(this.appPath), { recursive: true });
        const staging = join(dirname(this.appPath), `.Notess-install-${randomUUID()}.app`);
        const backup = join(dirname(this.appPath), `.Notess-backup-${randomUUID()}.app`);
        let backedUp = false;
        try {
            await command("/usr/bin/ditto", [builtApp, staging], { timeout: 60_000 });
            await command("/usr/bin/codesign", ["--verify", "--strict", staging]);
            signal.throwIfAborted();
            if (await this.isRunning()) throw new Error("Notess was opened during the build. Quit it and retry; the existing app is unchanged.");
            await this.readInstalled();
            if (await exists(this.appPath)) {
                await rename(this.appPath, backup);
                backedUp = true;
            }
            try {
                await rename(staging, this.appPath);
            } catch (error) {
                if (backedUp) {
                    try {
                        await rename(backup, this.appPath);
                    } catch (restoreError) {
                        throw new Error(`Installation failed. The previous app is preserved at ${backup}; restore it to ${this.appPath}. ${restoreError.message}`, { cause: error });
                    }
                    backedUp = false;
                }
                throw error;
            }
            if (backedUp) {
                await rm(backup, { recursive: true });
                backedUp = false;
            }
        } finally {
            await rm(staging, { recursive: true, force: true });
        }
    }

    async openApp() {
        if (this.job || await exists(this.lockPath)) throw new Error("Wait for the build to finish before opening Notess.");
        this.installed = await this.readInstalled();
        if (!this.installed) throw new Error("Build and install Notess first.");
        await run("/usr/bin/open", [this.appPath]);
        this.running = await this.isRunning();
        return this.snapshot();
    }

    async shutdown() {
        this.abortController?.abort();
        await this.job;
    }
}
