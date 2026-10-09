// Bundles each entry point into dist/ and copies static files.
// Usage: node build.mjs [--watch]
import * as esbuild from 'esbuild';
import { cpSync, mkdirSync, rmSync } from 'node:fs';

const watch = process.argv.includes('--watch');
const outdir = 'dist';

rmSync(outdir, { recursive: true, force: true });
mkdirSync(outdir, { recursive: true });
const copyStatic = () => cpSync('static', outdir, { recursive: true });
copyStatic();

const ctx = await esbuild.context({
  entryPoints: {
    background: 'src/background.ts',
    content: 'src/content.ts',
    offscreen: 'src/offscreen.ts',
    'test-page': 'src/test-page.ts',
  },
  outdir,
  bundle: true,
  format: 'iife',
  target: 'chrome116',
  sourcemap: watch ? 'inline' : false,
  logLevel: 'info',
  plugins: [{ name: 'copy-static', setup: (b) => b.onEnd(copyStatic) }],
});

if (watch) {
  await ctx.watch();
  console.log('Watching… reload the extension in brave://extensions after changes.');
} else {
  await ctx.rebuild();
  await ctx.dispose();
}
