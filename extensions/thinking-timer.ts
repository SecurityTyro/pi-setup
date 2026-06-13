/**
 * Thinking Timer Extension
 *
 * While the model is actively thinking (tokens hidden), cycles through an
 * animated dot sequence:  "Thinking." → "Thinking.." → "Thinking..."
 *
 * When thinking finishes, replaces it with the total elapsed time:
 *   "💭 Thought for 3s"  /  "💭 Thought for 2min 15s"
 *
 * The label is only rendered when thinking blocks are collapsed
 * (hideThinkingBlock: true).  When blocks are visible the timer runs
 * harmlessly in the background.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const DOT_FRAMES = ["Thinking.", "Thinking..", "Thinking..."];
const DOT_INTERVAL_MS = 500;

function formatElapsed(ms: number): string {
	const totalSeconds = Math.floor(ms / 1000);
	if (totalSeconds < 60) {
		return `💭 Thought for ${totalSeconds}s`;
	}
	const minutes = Math.floor(totalSeconds / 60);
	const seconds = totalSeconds % 60;
	if (seconds === 0) {
		return `💭 Thought for ${minutes}min`;
	}
	return `💭 Thought for ${minutes}min ${seconds}s`;
}

export default function (pi: ExtensionAPI) {
	let thinkingStartTime: number | null = null;
	let animationInterval: ReturnType<typeof setInterval> | null = null;
	let dotFrame = 0;

	function updateLabel(ctx: { ui: { setHiddenThinkingLabel(label?: string): void } }, label: string) {
		ctx.ui.setHiddenThinkingLabel(label);
	}

	function startAnimation(ctx: { ui: { setHiddenThinkingLabel(label?: string): void } }) {
		thinkingStartTime = Date.now();
		dotFrame = 0;
		updateLabel(ctx, DOT_FRAMES[0]);

		animationInterval = setInterval(() => {
			dotFrame = (dotFrame + 1) % DOT_FRAMES.length;
			updateLabel(ctx, DOT_FRAMES[dotFrame]);
		}, DOT_INTERVAL_MS);
	}

	function stopAnimation(ctx: { ui: { setHiddenThinkingLabel(label?: string): void } }) {
		if (animationInterval !== null) {
			clearInterval(animationInterval);
			animationInterval = null;
		}

		if (thinkingStartTime !== null) {
			const elapsed = Date.now() - thinkingStartTime;
			updateLabel(ctx, formatElapsed(elapsed));
			thinkingStartTime = null;
		} else {
			// No thinking was tracked – reset to default.
			ctx.ui.setHiddenThinkingLabel();
		}
	}

	function resetToDefault(ctx: { ui: { setHiddenThinkingLabel(label?: string): void } }) {
		if (animationInterval !== null) {
			clearInterval(animationInterval);
			animationInterval = null;
		}
		thinkingStartTime = null;
		ctx.ui.setHiddenThinkingLabel();
	}

	pi.on("message_update", async (event, ctx) => {
		const evt = event.assistantMessageEvent;
		if (!evt) return;

		if (evt.type === "thinking_start" && thinkingStartTime === null) {
			startAnimation(ctx);
		} else if (
			(evt.type === "thinking_end" ||
				evt.type === "text_start" ||
				evt.type === "toolcall_start") &&
			thinkingStartTime !== null
		) {
			// Thinking is done — show the final elapsed time.
			stopAnimation(ctx);
		}
	});

	// Safety nets — clean up on any turn / agent completion.
	pi.on("message_end", async (_event, ctx) => {
		if (thinkingStartTime !== null) resetToDefault(ctx);
	});

	pi.on("turn_end", async (_event, ctx) => {
		if (thinkingStartTime !== null) resetToDefault(ctx);
	});

	pi.on("agent_end", async (_event, ctx) => {
		if (thinkingStartTime !== null) resetToDefault(ctx);
	});
}
