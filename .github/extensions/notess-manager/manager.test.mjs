import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { access, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import test from "node:test";
import { createManager, nextBuildNumber, run } from "./manager.mjs";

const infoPlist = await readFile(new URL("../../../Support/Info.plist", import.meta.url), "utf8");
const builder = `#!/bin/bash
set -euo pipefail
app="$OUTPUT_DIR/Notess.app"
mkdir -p "$app/Contents/MacOS"
cp Support/Info.plist "$app/Contents/Info.plist"
cp /bin/sleep "$app/Contents/MacOS/Notess"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
`;

async function waitFor(predicate) {
    const deadline = Date.now() + 15_000;
    while (!await predicate()) {
        assert.ok(Date.now() < deadline, "The operation did not finish before its deadline.");
        await delay(10);
    }
}

async function fixture(t) {
    const root = await mkdtemp(join(tmpdir(), "notess-manager-test-"));
    const repo = join(root, "repo");
    const remote = join(root, "origin.git");
    const appPath = join(root, "Applications", "Notess.app");
    const storagePath = join(root, "state");
    const managers = [];
    t.after(async () => {
        for (const manager of managers) await manager.shutdown();
        await rm(root, { recursive: true, force: true });
    });
    const git = (...args) => run("git", ["-C", repo, ...args]);
    await run("git", ["init", "--bare", "--initial-branch=main", remote]);
    await run("git", ["init", "--initial-branch=main", repo]);
    await git("config", "user.name", "Notess fixture");
    await git("config", "user.email", "test@example.invalid");
    await git("remote", "add", "origin", remote);
    await mkdir(join(repo, "Support"));
    await mkdir(join(repo, "scripts"));
    await writeFile(join(repo, "Support", "Info.plist"), infoPlist);
    await writeFile(join(repo, "scripts", "build-app.sh"), builder);
    const commit = async (message) => {
        await git("add", ".");
        await git("commit", "-m", message);
        await git("push", "origin", "main");
        return (await git("rev-parse", "HEAD")).stdout;
    };
    const revision = await commit("Fixture app");
    const manager = async () => {
        const value = await createManager(repo, { appPath, storagePath });
        managers.push(value);
        return value;
    };
    return { root, repo, appPath, storagePath, git, revision, commit, manager };
}

async function build(manager) {
    const started = await manager.startBuild();
    assert.equal(started.busy, true);
    await waitFor(() => !manager.snapshot().busy);
    const state = manager.snapshot();
    assert.equal(state.error, null);
    return state;
}

test("build numbers advance locally and invalid numbers are rejected", () => {
    assert.equal(nextBuildNumber(undefined), "1");
    assert.equal(nextBuildNumber("9.1"), "10");
    assert.equal(nextBuildNumber("123.2.3"), "124");
    assert.throws(() => nextBuildNumber("preview"), /Cannot increment/);
    assert.throws(() => nextBuildNumber("0"), /Cannot increment/);
});

test("builds remote main, preserves dirty checkout, and tracks the installed source across fresh managers", async (t) => {
    const f = await fixture(t);
    await writeFile(join(f.repo, "scripts", "build-app.sh"), "exit 99\n");
    await writeFile(join(f.repo, "local-only.txt"), "Do not include this edit.\n");
    const before = (await f.git("status", "--porcelain")).stdout;
    const manager = await f.manager();
    const initial = await manager.refresh(true);
    assert.equal(initial.installed, null);
    assert.equal(initial.latestRevision, f.revision);
    assert.equal(initial.updateAvailable, true);
    const installed = await build(manager);
    assert.deepEqual(installed.installed, { build: "1", version: "0.1.0", revision: f.revision });
    await run("/usr/bin/codesign", ["--verify", "--strict", f.appPath]);
    assert.equal((await f.git("status", "--porcelain")).stdout, before);
    assert.equal((await f.git("rev-parse", "HEAD")).stdout, f.revision);
    const reopened = await f.manager();
    const current = await reopened.refresh(true);
    assert.equal(current.updateAvailable, false);
    assert.deepEqual(current.installed, installed.installed);
    await assert.rejects(reopened.startBuild(), /already installed/);
    await assert.rejects(access(current.lockPath), { code: "ENOENT" });
});

test("an updated main advances the build and replaces rather than merges the installed bundle", async (t) => {
    const f = await fixture(t);
    const manager = await f.manager();
    await build(manager);
    await writeFile(join(f.appPath, "obsolete-resource"), "old");
    await writeFile(join(f.repo, "new.txt"), "new main");
    const revision = await f.commit("Next main");
    assert.equal((await manager.refresh(true)).updateAvailable, true);
    const state = await build(manager);
    assert.equal(state.installed.build, "2");
    assert.equal(state.installed.revision, revision);
    await assert.rejects(access(join(f.appPath, "obsolete-resource")), { code: "ENOENT" });
    assert.equal((await manager.refresh(true)).updateAvailable, false);
});

test("an explicit main check is not swallowed by an in-flight cached status read", async (t) => {
    const f = await fixture(t);
    const manager = await f.manager();
    await manager.refresh(true);
    await writeFile(join(f.repo, "update.txt"), "new main");
    const revision = await f.commit("Advance main");
    const cached = manager.refresh();
    const forced = manager.refresh(true);
    await cached;
    assert.equal((await forced).latestRevision, revision);
});

test("a failed build leaves the previous app and its source metadata untouched", async (t) => {
    const f = await fixture(t);
    const manager = await f.manager();
    await build(manager);
    const before = await readFile(join(f.appPath, "Contents", "Info.plist"));
    await writeFile(join(f.repo, "scripts", "build-app.sh"), "exit 42\n");
    await f.commit("Failing main");
    await manager.startBuild();
    await waitFor(() => !manager.snapshot().busy);
    assert.match(manager.snapshot().error, /exited 42/);
    assert.deepEqual(await readFile(join(f.appPath, "Contents", "Info.plist")), before);
    await assert.rejects(access(manager.snapshot().lockPath), { code: "ENOENT" });
    await run("/usr/bin/codesign", ["--verify", "--strict", f.appPath]);
});

test("a signed app with the wrong source metadata is rejected before replacement", async (t) => {
    const f = await fixture(t);
    const manager = await f.manager();
    await build(manager);
    const before = await readFile(join(f.appPath, "Contents", "Info.plist"));
    await writeFile(join(f.repo, "scripts", "build-app.sh"), builder.replace(
        "/usr/bin/codesign", '/usr/bin/plutil -remove NotessSourceRevision "$app/Contents/Info.plist"\n/usr/bin/codesign'));
    await f.commit("Missing revision");
    await manager.startBuild();
    await waitFor(() => !manager.snapshot().busy);
    assert.match(manager.snapshot().error, /does not match/);
    assert.deepEqual(await readFile(join(f.appPath, "Contents", "Info.plist")), before);
});

test("a second manager cannot build concurrently and interruption releases the lock", async (t) => {
    const f = await fixture(t);
    const marker = join(f.root, "building");
    await writeFile(join(f.repo, "scripts", "build-app.sh"),
        `touch "${marker}"\nwhile :; do /bin/sleep 1; done\n`);
    await f.commit("Wait for interruption");
    const first = await f.manager();
    const second = await f.manager();
    await first.startBuild();
    await waitFor(async () => {
        try { await access(marker); return true; }
        catch (error) { if (error.code === "ENOENT") return false; throw error; }
    });
    assert.equal((await second.refresh(true)).locked, true);
    await assert.rejects(second.startBuild(), /Another build holds/);
    await first.shutdown();
    assert.match(first.snapshot().error, /interrupted|aborted/);
    assert.equal(first.snapshot().busy, false);
    await assert.rejects(access(first.snapshot().lockPath), { code: "ENOENT" });
    await assert.rejects(access(f.appPath), { code: "ENOENT" });
});

test("a running installed executable blocks replacement without quitting the process", async (t) => {
    const f = await fixture(t);
    const manager = await f.manager();
    await build(manager);
    await writeFile(join(f.repo, "update.txt"), "next main");
    await f.commit("Next main");
    const child = spawn(join(f.appPath, "Contents", "MacOS", "Notess"), ["60"], { stdio: "ignore" });
    await once(child, "spawn");
    try {
        assert.equal((await manager.refresh(true)).running, true);
        await assert.rejects(manager.startBuild(), /Quit Notess/);
        assert.equal(child.exitCode, null);
        assert.equal(manager.snapshot().installed.build, "1");
    } finally {
        const closed = once(child, "close");
        child.kill("SIGTERM");
        await closed;
    }
});

test("missing apps cannot be opened and symlink destinations are never replaced", async (t) => {
    const f = await fixture(t);
    const manager = await f.manager();
    await assert.rejects(manager.openApp(), /Build and install/);
    await mkdir(join(f.root, "Applications"));
    const other = join(f.root, "other");
    await mkdir(other);
    await symlink(other, f.appPath);
    const state = await manager.refresh(true);
    assert.match(state.checkError, /symlink/);
    await assert.rejects(manager.startBuild(), /symlink/);
    await access(other);
});
