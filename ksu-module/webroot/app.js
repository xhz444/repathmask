/*
 * PkgMask / PathMask Fusion WebUI.
 * Serves both package flavours:
 *   - pure PkgMask   (KSU id=pkgmask,  conf dir /data/adb/pkgmask)
 *   - PathMask Fusion (KSU id=pathmask, conf dir /data/adb/pathmask,
 *                      adds procguard + scene watcher status cards)
 * The active flavour is auto-detected from the installed module dir.
 * KernelSU bridge usage (exec with callback name, 2-arg fallback) follows
 * the original LKM-PathMask webroot/app.js.
 */
"use strict";

const CANDIDATE_MOD_DIRS = [
	"/data/adb/modules/pathmask", // fusion first: it shares the id with the
	"/data/adb/modules/pkgmask",  // legacy loader the user upgrades from
];

let MOD_DIR = "";
let CONF_DIR = "";
let FILES = {};

const $ = (sel) => document.querySelector(sel);

let busy = false;
let hidePackages = [];

function shellQuote(value) {
	return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function getKsuBridge() {
	if (typeof window !== "undefined" && window.ksu?.exec) return window.ksu;
	if (typeof ksu !== "undefined" && ksu?.exec) return ksu;
	return null;
}

function execShell(command, timeoutMs = 90000) {
	const bridge = getKsuBridge();
	if (!bridge) return Promise.reject(new Error("KernelSU WebUI API 不可用"));

	return new Promise((resolve, reject) => {
		const callbackName = `pkgmask_exec_${Date.now()}_${Math.random().toString(16).slice(2)}`;
		let timer = null;

		/* Timeout guard: some manager builds never invoke the exec
		 * callback for long-running commands, which used to leave the
		 * WebUI stuck in the busy state forever. */
		const cleanup = () => {
			clearTimeout(timer);
			delete window[callbackName];
		};
		const fail = (err) => {
			cleanup();
			reject(err);
		};

		window[callbackName] = (errno, stdout, stderr) => {
			cleanup();
			if (errno && errno !== 0) {
				const err = new Error(stderr || stdout || `命令失败：${errno}`);
				err.errno = errno;
				err.stderr = stderr || "";
				err.stdout = stdout || "";
				reject(err);
				return;
			}
			resolve(stdout || "");
		};

		timer = setTimeout(() => {
			const err = new Error(`命令超时（${Math.round(timeoutMs / 1000)} 秒），已放弃等待`);
			err.errno = -1;
			fail(err);
		}, timeoutMs);

		try {
			bridge.exec(command, JSON.stringify({}), callbackName);
		} catch {
			try {
				bridge.exec(command, callbackName);
			} catch (fallbackError) {
				fail(fallbackError);
			}
		}
	});
}

async function safeExec(command) {
	try {
		return await execShell(command);
	} catch (error) {
		return `ERROR: ${error.message}`;
	}
}

function showToast(message) {
	const el = $("#toast");
	el.textContent = message;
	el.hidden = false;
	clearTimeout(showToast.timer);
	showToast.timer = setTimeout(() => {
		el.hidden = true;
	}, 4200);
}

function setBusy(nextBusy, message = null) {
	busy = nextBusy;
	$("#saveReloadBtn").disabled = nextBusy;
	$("#pkgAddBtn").disabled = nextBusy;
	if (message !== null) $("#statusText").textContent = message;
}

/* ---- path detection ------------------------------------------------------ */

async function detectPaths() {
	for (const dir of CANDIDATE_MOD_DIRS) {
		const out = await safeExec(`[ -f ${shellQuote(`${dir}/service.sh`)} ] && echo yes || echo no`);
		if (out.trim() === "yes") {
			MOD_DIR = dir;
			break;
		}
	}
	if (!MOD_DIR) MOD_DIR = "/data/adb/modules/pkgmask";

	const fusion = MOD_DIR.endsWith("/pathmask");
	CONF_DIR = fusion ? "/data/adb/pathmask" : "/data/adb/pkgmask";
	FILES = {
		hidePackages: `${CONF_DIR}/hide_packages.conf`,
		exemptPackages: `${CONF_DIR}/exempt_packages.conf`,
		exemptUids: `${CONF_DIR}/exempt_uids.conf`,
		systemUids: `${MOD_DIR}/system_uids.conf`,
		state: `${CONF_DIR}/state.json`,
		log: `${CONF_DIR}/service.log`,
		service: `${MOD_DIR}/service.sh`,
		moduleProp: `${MOD_DIR}/module.prop`,
	};
}

/* ---- config file helpers -------------------------------------------------- */

function parseConfLines(text) {
	return String(text || "")
		.split("\n")
		.map((line) => line.replace(/#.*$/, "").trim())
		.filter((line) => line.length > 0);
}

async function readConf(path) {
	const out = await safeExec(`[ -f ${shellQuote(path)} ] && cat ${shellQuote(path)} || true`);
	return out.startsWith("ERROR:") ? "" : out;
}

/* Writing confs line-by-line keeps everything ASCII-quoted and avoids any
 * newline-in-argument trouble with the bridge. Data lines are validated to
 * be [A-Za-z0-9._] or digits, so quoting is trivially safe. */
async function writeConf(path, lines) {
	if (!lines.length) {
		return execShell(`: > ${shellQuote(path)}`);
	}
	const echoArgs = lines.map(shellQuote).join(" ");
	return execShell(`printf '%s\\n' ${echoArgs} > ${shellQuote(path)}`);
}

const PKG_RE = /^[A-Za-z0-9._]+$/;
const UID_RE = /^[0-9]+$/;

/* ---- hide package list ----------------------------------------------------- */

function renderPkgList() {
	const ul = $("#pkgList");
	ul.textContent = "";
	$("#pkgEmpty").hidden = hidePackages.length > 0;
	for (const pkg of hidePackages) {
		const li = document.createElement("li");
		const name = document.createElement("span");
		name.textContent = pkg;
		name.className = "pkg-name";
		const del = document.createElement("button");
		del.className = "btn btn-sm btn-danger";
		del.textContent = "移除";
		del.addEventListener("click", () => {
			hidePackages = hidePackages.filter((p) => p !== pkg);
			renderPkgList();
		});
		li.append(name, del);
		ul.append(li);
	}
}

function addPkgFromInput() {
	const input = $("#pkgInput");
	const value = input.value.trim();
	if (!value) return;
	if (!PKG_RE.test(value)) {
		showToast("包名只能包含字母、数字、点、下划线");
		return;
	}
	if (hidePackages.includes(value)) {
		showToast("该包名已在列表中");
		return;
	}
	hidePackages.push(value);
	input.value = "";
	renderPkgList();
}

/* ---- status ---------------------------------------------------------------- */

function statusCard(label, value, cls) {
	return `<div class="card"><div class="card-label">${label}</div><div class="card-value ${cls || ""}">${value}</div></div>`;
}

function esc(text) {
	return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

const PG_TEXT = {
	"loaded": "已加载",
	"already-loaded": "已加载（开机时）",
	"failed": "加载失败",
	"missing": "ko 缺失",
	"vermagic-mismatch": "vermagic 不匹配",
};
const SCENE_TEXT = {
	"started": "已启动",
	"already-running": "运行中",
	"package-absent": "未装 Scene，未启动",
	"disabled": "已禁用",
	"no-script": "本包未包含",
};

async function refreshStatus() {
	const [stateOut, modsOut, verOut] = await Promise.all([
		readConf(FILES.state),
		safeExec(`grep -E '^(pkgmask|procguard) ' /proc/modules 2>/dev/null || true`),
		readConf(FILES.moduleProp),
	]);

	let state = null;
	try {
		state = JSON.parse(stateOut);
	} catch {
		/* missing/corrupt state */
	}

	const fusion = Boolean(state?.fusion);
	const pkgLoaded = /^pkgmask /m.test(modsOut);
	const pgLoaded = /^procguard /m.test(modsOut);
	const version = (verOut.match(/^version=(.*)$/m) || [])[1] || "";
	$("#verTag").textContent = version ? `${version}${fusion ? " · Fusion" : ""}` : "";

	const pill = $("#statusPill");
	if (pkgLoaded && (state?.pkgmask?.loaded !== false || !state?.pkgmask)) {
		pill.textContent = "运行中";
		pill.className = "pill pill-ok";
	} else if (fusion && pgLoaded) {
		pill.textContent = "部分运行（隐藏未激活）";
		pill.className = "pill pill-warn";
	} else if (state?.pkgmask && state.pkgmask.fail_count >= 3) {
		pill.textContent = "已熔断";
		pill.className = "pill pill-bad";
	} else {
		pill.textContent = "未加载";
		pill.className = "pill pill-bad";
	}

	let cards = "";
	if (state) {
		const p = state.pkgmask || state; /* flat fallback for pure builds */
		const pkgRows = (p.packages || [])
			.map((row) => {
				const statusText =
					row.status === "hidden" ? `隐藏中 (uid ${row.uid})` :
					row.status === "hidden-no-owner-uid" ? "隐藏中（未解析到属主 uid）" :
					row.status === "not-installed" ? "未安装，无需隐藏" :
					"包名无效";
				return `<tr><td>${esc(row.package)}</td><td>${esc(statusText)}</td></tr>`;
			})
			.join("");
		cards += statusCard("内核", esc(state.kernel || "?"));
		cards += statusCard("KMI 猜测", esc(state.kmi_guess || "?"));
		cards += statusCard("pkgmask 状态", pkgLoaded ? `<span class="ok">已加载</span>` : `<span class="bad">未加载</span>`);
		cards += statusCard("已解析目标", `${p.resolved_count ?? 0} / ${p.target_count ?? 0}`,
			p.resolved_count === p.target_count ? "ok" : "warn");
		cards += statusCard("写操作策略", p.policy || "?");
		cards += statusCard("详情", esc(p.detail || ""));

		if (fusion) {
			cards += statusCard("procguard", pgLoaded
				? `<span class="ok">已加载</span>`
				: esc(PG_TEXT[state.procguard?.status] || state.procguard?.status || "未知"));
			if (state.procguard?.ko_vermagic && state.procguard.ko_vermagic !== "unknown") {
				cards += statusCard("procguard vermagic", esc(state.procguard.ko_vermagic));
			}
			cards += statusCard("Scene 监视", esc(SCENE_TEXT[state.scene?.status] || state.scene?.status || "未知"));
		}

		if (pkgRows) {
			cards += `<div class="card card-wide"><div class="card-label">包处理结果</div><table class="pkgtable"><tbody>${pkgRows}</tbody></table></div>`;
		}
		if (p.targets?.length) {
			cards += `<div class="card card-wide"><div class="card-label">内核 target（前 8 条，共 ${p.targets.length}）</div><pre class="targets">${esc(p.targets.slice(0, 8).join("\n"))}</pre></div>`;
		}
	} else {
		cards += statusCard("状态", "尚无 state.json（service.sh 未运行？重启或点热重载）", "warn");
	}
	$("#statusCards").innerHTML = cards;
}

async function refreshLogs() {
	const [logOut, dmesgOut] = await Promise.all([
		safeExec(`[ -f ${shellQuote(FILES.log)} ] && tail -n 120 ${shellQuote(FILES.log)} || echo '(无服务日志)'`),
		safeExec(`dmesg 2>/dev/null | grep -iE 'pkgmask|procguard|scene-debugfs' | tail -n 40 || true`),
	]);
	$("#logView").textContent = logOut || "(空)";
	$("#dmesgView").textContent = dmesgOut || "(无相关 dmesg)";
}

/* ---- diagnostic report ------------------------------------------------------ */

async function copyDiagnostic() {
	setBusy(true, "正在生成诊断报告…");
	try {
		const q = (p) => shellQuote(p);
		const report = await execShell(
			`echo '=== PkgMask 诊断报告 ==='; date; ` +
			`echo; echo '--- state.json ---'; cat ${q(FILES.state)} 2>/dev/null || echo '(无)'; ` +
			`echo; echo '--- 内核/模块 ---'; uname -a; grep -E '^(pkgmask|procguard) ' /proc/modules 2>/dev/null || echo '(无内核模块)'; ` +
			`echo; echo '--- 配置 ---'; ` +
			`for f in hide_packages exempt_packages exempt_uids system_uids; do echo "[$f]"; cat ${q(`${CONF_DIR}/$f.conf`)} 2>/dev/null || echo '(无)'; done; ` +
			`echo; echo '--- 服务日志(尾60) ---'; tail -n 60 ${q(FILES.log)} 2>/dev/null || echo '(无)'; ` +
			`echo; echo '--- dmesg(尾40) ---'; dmesg 2>/dev/null | grep -iE 'pkgmask|procguard|scene-debugfs' | tail -n 40 || true`
		);

		let copied = false;
		try {
			copied = await navigator.clipboard.writeText(report).then(() => true, () => false);
		} catch {
			copied = false;
		}
		if (!copied) {
			const ta = document.createElement("textarea");
			ta.value = report;
			ta.style.position = "fixed";
			ta.style.opacity = "0";
			document.body.append(ta);
			ta.select();
			copied = document.execCommand("copy");
			ta.remove();
		}
		showToast(copied ? "诊断报告已复制" : "复制失败，请截图状态页");
	} catch (error) {
		showToast(`生成诊断失败：${error.message}`);
	} finally {
		setBusy(false, "");
	}
}

/* ---- save & hot reload ------------------------------------------------------- */

async function saveAndReload() {
	if (busy) {
		showToast("正在处理，请稍等");
		return;
	}

	const exemptPkgs = parseConfLines($("#exemptPkgText").value);
	const exemptUids = parseConfLines($("#exemptUidText").value);
	if (exemptPkgs.some((p) => !PKG_RE.test(p))) {
		showToast("豁免包名列表里有非法字符");
		return;
	}
	if (exemptUids.some((u) => !UID_RE.test(u))) {
		showToast("豁免 UID 列表里有非数字");
		return;
	}

	setBusy(true, "正在保存并热重载…");
	try {
		await writeConf(FILES.hidePackages, hidePackages);
		await writeConf(FILES.exemptPackages, exemptPkgs);
		await writeConf(FILES.exemptUids, exemptUids);

		/* Foreground single exec, same shape as the original project's
		 * reload: rmmod first (with guard), short storage wait, then
		 * service.sh, then the load check. The detached variant used
		 * before turned out to get reaped by the manager's exec cleanup,
		 * which is why the countdown never finished. The 75s JS timeout
		 * below is the last-resort guard so the UI can never hang. */
		const out = await execShell(
			`if grep -q '^pkgmask ' /proc/modules 2>/dev/null; then rmmod pkgmask || exit 20; fi; ` +
			`PKGMASK_RESET_FAIL_GUARD=1 PKGMASK_INITIAL_DELAY=0 PKGMASK_WAIT_SECONDS=5 ` +
			`sh ${shellQuote(FILES.service)} 2>&1 | tail -n 15; ` +
			`grep -q '^pkgmask ' /proc/modules && echo MODULE_LOADED=yes || echo MODULE_LOADED=no`,
			75000
		);
		const loaded = /MODULE_LOADED=yes/.test(out);
		showToast(loaded ? "已热重载" : "未能加载 pkgmask，请看状态与日志");
	} catch (error) {
		if (error.errno === 20) {
			showToast("rmmod 失败，旧实例仍在；请稍后重试或重启");
		} else {
			showToast(`热重载失败：${error.message}`);
		}
	} finally {
		setBusy(false, "");
		await refreshStatus();
		await refreshLogs();
	}
}

/* ---- init --------------------------------------------------------------------- */

function switchTab(tabName) {
	for (const btn of document.querySelectorAll(".tab")) {
		btn.classList.toggle("active", btn.dataset.tab === tabName);
	}
	for (const panel of document.querySelectorAll(".panel")) {
		panel.classList.toggle("active", panel.id === `tab-${tabName}`);
	}
}

async function init() {
	document.querySelectorAll(".tab").forEach((btn) =>
		btn.addEventListener("click", () => switchTab(btn.dataset.tab))
	);
	$("#pkgAddBtn").addEventListener("click", addPkgFromInput);
	$("#pkgInput").addEventListener("keydown", (e) => {
		if (e.key === "Enter") addPkgFromInput();
	});
	$("#saveReloadBtn").addEventListener("click", saveAndReload);
	$("#refreshLogBtn").addEventListener("click", refreshLogs);
	$("#diagBtn").addEventListener("click", copyDiagnostic);

	await detectPaths();

	const [hideOut, exemptPkgOut, exemptUidOut, sysUidOut] = await Promise.all([
		readConf(FILES.hidePackages),
		readConf(FILES.exemptPackages),
		readConf(FILES.exemptUids),
		readConf(FILES.systemUids),
	]);

	hidePackages = parseConfLines(hideOut);
	renderPkgList();
	$("#exemptPkgText").value = parseConfLines(exemptPkgOut).join("\n");
	$("#exemptUidText").value = parseConfLines(exemptUidOut).join("\n");
	$("#systemUidView").textContent = parseConfLines(sysUidOut).join("  ");

	await refreshStatus();
	await refreshLogs();
}

init().catch((error) => showToast(`初始化失败：${error.message}`));
