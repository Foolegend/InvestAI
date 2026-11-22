/**
 * Preload for running the source snapshot directly with Bun.
 *
 * Defines the build-time `MACRO` object that the bundler normally injects
 * (see `bun build --define MACRO.VERSION=...` in the upstream build).
 *
 * Real values for the private feedback/changelog channels are unknown; the
 * placeholders keep paths that read them from crashing.
 */

const VERSION = process.env.CLAUDE_CODE_VERSION ?? '2.1.330';

;(globalThis as any).MACRO = {
  VERSION,
  PACKAGE_URL: 'https://www.npmjs.com/package/@anthropic-ai/claude-code',
  NATIVE_PACKAGE_URL: 'https://www.npmjs.com/package/@anthropic-ai/claude-code',
  FEEDBACK_CHANNEL: 'https://github.com/anthropics/claude-code/issues',
  BUILD_TIME: new Date().toISOString(),
  VERSION_CHANGELOG: '',
  ISSUES_EXPLAINER: 'https://github.com/anthropics/claude-code/issues',
};
