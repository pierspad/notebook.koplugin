import { readFileSync, writeFileSync } from 'node:fs';
const version = process.argv[2];
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version ?? '')) {
  throw new Error('Expected a semantic version');
}
const file = new URL('../lua/_meta.lua', import.meta.url);
const source = readFileSync(file, 'utf8');
if ((source.match(/version = "[^"]+"/g) ?? []).length !== 1) {
  throw new Error('Expected exactly one plugin version');
}
writeFileSync(file, source.replace(/version = "[^"]+"/, `version = "v${version}"`));
