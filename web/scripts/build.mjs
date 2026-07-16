import { build } from 'esbuild';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const webDirectory = path.resolve(root, '..');
const outputDirectory = path.resolve(webDirectory, '..', 'assets');

const result = await build({
  bundle: true,
  entryPoints: [path.join(webDirectory, 'src', 'vtk_locator.js')],
  format: 'esm',
  legalComments: 'none',
  loader: { '.glsl': 'text' },
  metafile: true,
  minify: true,
  outfile: path.join(outputDirectory, 'vtk_locator.js'),
  platform: 'browser',
  target: 'es2022',
});

const bundlePath = path.join(outputDirectory, 'vtk_locator.js');
const bundle = await readFile(bundlePath, 'utf8');
await writeFile(bundlePath, bundle.replace(/[\t ]+$/gm, ''));

const packageNameFromInput = (input) => {
  const marker = 'node_modules/';
  const start = input.lastIndexOf(marker);
  if (start < 0) return null;
  const parts = input.slice(start + marker.length).split('/');
  return parts[0].startsWith('@') ? `${parts[0]}/${parts[1]}` : parts[0];
};

const packages = [...new Set(
  Object.keys(result.metafile.inputs).map(packageNameFromInput).filter(Boolean),
)].sort();

const notices = [];
for (const packageName of packages) {
  const packageDirectory = path.join(webDirectory, 'node_modules', packageName);
  const packageMetadata = JSON.parse(
    await readFile(path.join(packageDirectory, 'package.json'), 'utf8'),
  );
  const entries = await readdir(packageDirectory);
  const licenseFile = entries.find((entry) => /^licen[cs]e(?:\.|$)/i.test(entry));
  let licenseText;
  if (licenseFile) {
    licenseText = await readFile(path.join(packageDirectory, licenseFile), 'utf8');
  } else if (packageName === 'seedrandom') {
    const source = await readFile(path.join(packageDirectory, 'seedrandom.js'), 'utf8');
    licenseText = source.match(/^\/\*([\s\S]*?)\*\//)?.[1]?.trim();
  }
  if (!licenseText) {
    throw new Error(`No license text found for bundled package ${packageName}`);
  }
  notices.push(
    `${packageName} ${packageMetadata.version} (${packageMetadata.license})\n\n${licenseText.trim()}`,
  );
}

await writeFile(
  path.join(outputDirectory, 'vtk_locator.LICENSE.txt'),
  `Generated from web/package-lock.json by web/scripts/build.mjs.\n\n${notices.join('\n\n---\n\n')}\n`,
);
