/**
 * Context Command Extension
 *
 * /context - Show detailed context usage with visual bar, breakdown, and tools.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { DynamicBorder } from "@earendil-works/pi-coding-agent";
import { Container, Text, Spacer } from "@earendil-works/pi-tui";

// ─── Token estimation (rough: ~4 chars per token) ───────────────────────────

function estimateTokens(text: string): number {
	return Math.ceil(text.length / 4);
}

function fmt(n: number): string {
	if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
	if (n >= 1000) return (n / 1000).toFixed(1) + "K";
	return String(n);
}

// ─── Extension ───────────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
	pi.registerCommand("context", {
		description: "Show detailed context usage breakdown",
		handler: async (_args, ctx) => {
			const usage = ctx.getContextUsage();
			const totalTokens = usage?.tokens ?? 0;
			const limit = usage?.limit ?? ctx.model?.contextWindow ?? 128000;
			const pct = limit > 0 ? (totalTokens / limit) * 100 : 0;

			// Estimate breakdown
			const systemPrompt = ctx.getSystemPrompt() ?? "";
			const sysPromptTokens = estimateTokens(systemPrompt);

			const allTools = pi.getAllTools();
			const toolTokens = allTools.reduce((sum: number, t: any) => {
				return sum + estimateTokens(t.name + " " + (t.description ?? ""));
			}, 0);

			const branch = ctx.sessionManager.getBranch();
			let msgTokens = 0;
			let msgCount = 0;
			for (const entry of branch) {
				if (entry.type === "message") {
					const content = JSON.stringify((entry as any).message?.content ?? "");
					msgTokens += estimateTokens(content);
					msgCount++;
				}
			}

			const accounted = sysPromptTokens + toolTokens + msgTokens;
			const miscTokens = Math.max(0, totalTokens - accounted);
			const freeTokens = Math.max(0, limit - totalTokens);

			const activeTools = pi.getActiveTools();

			// Render as TUI overlay
			await ctx.ui.custom<void | null>(
				(tui, theme, _kb, done) => {
					const container = new Container();

					// ── Top border ──
					container.addChild(new DynamicBorder((s: string) => theme.fg("accent", s)));

					// ── Title bar with usage ──
					const barWidth = 20;
					const filled = Math.round((pct / 100) * barWidth);
					const barStr = "█".repeat(filled) + "░".repeat(barWidth - filled);
					const barColor = pct > 80 ? theme.fg("error", barStr) : pct > 50 ? theme.fg("warning", barStr) : theme.fg("success", barStr);
					const pctStr = pct > 80 ? theme.fg("error", `${pct.toFixed(1)}%`) : pct > 50 ? theme.fg("warning", `${pct.toFixed(1)}%`) : theme.fg("success", `${pct.toFixed(1)}%`);

					container.addChild(new Text(
						` ${theme.fg("accent", theme.bold("Context"))} ${barColor} ${pctStr} ${theme.fg("dim", fmt(totalTokens) + "/" + fmt(limit))}`,
						1, 0
					));
					container.addChild(new Text(
						` ${theme.fg("dim", "Model:")} ${theme.fg("accent", ctx.model?.id || "unknown")}  ${theme.fg("dim", msgCount + " msgs · " + fmt(msgTokens))}`,
						1, 0
					));
					container.addChild(new Spacer(1));

					// ── Breakdown (compact table) ──
					const allBreakdown: [string, number, string][] = [
						["System", sysPromptTokens, "accent"],
						["Tools", toolTokens, "mdLink"],
						["Messages", msgTokens, "accent"],
						["Other", miscTokens, "dim"],
						["Free", freeTokens, "success"],
					];

					const maxL = Math.max(...allBreakdown.filter(([_, t]) => t > 0).map(([l]) => l.length));
					for (const [label, tokens, color] of allBreakdown) {
						if (tokens === 0) continue;
						const itemPct = limit > 0 ? ((tokens / limit) * 100) : 0;
						// Show a small 5-char bar proportional to this item's share of limit
						const shortBar = Math.round((itemPct / 100) * 5);
						const bar = shortBar > 0 ? "█".repeat(shortBar) + "░".repeat(5 - shortBar) : "▏░░░░";
						const coloredBar = theme.fg(color as any, bar);
						const padded = label.padEnd(maxL);
						container.addChild(new Text(
							` ${coloredBar} ${theme.fg("dim", padded)} ${theme.fg("text", fmt(tokens).padStart(6))} ${theme.fg("dim", itemPct.toFixed(1) + "%")}`,
							1, 0
						));
					}

					container.addChild(new Spacer(1));

					// ── Tools (compact single line) ──
					if (allTools.length > 0) {
						const names = allTools.map((t: any) => t.name);
						const activeNames = new Set(
							activeTools.map((t: any) => typeof t === "string" ? t : t.name)
						);
						// Highlight active tools, dim inactive
						const parts = names.map((n: string) =>
							activeNames.has(n)
								? theme.fg("text", n)
								: theme.fg("dim", n)
						);
						container.addChild(new Text(
							` ${theme.fg("dim", "Tools:")} ${parts.join(theme.fg("dim", " · "))}`,
							1, 0
						));
						container.addChild(new Spacer(1));
					}

					// ── Footer ──
					container.addChild(new Text(` ${theme.fg("dim", "Any key to close")}`, 1, 0));

					// ── Bottom border ──
					container.addChild(new DynamicBorder((s: string) => theme.fg("accent", s)));

					return {
						render: (w) => container.render(w),
						invalidate: () => container.invalidate(),
						handleInput: () => done(null),
					};
				},
				{ overlay: true },
			);
		},
	});
}
