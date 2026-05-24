#!/usr/bin/env node
'use strict';

import { appendFileSync } from 'node:fs';

const VALID_CHANNELS = new Set(['stable', 'beta']);
const STORAGE_BASE =
  process.env.FLUTTER_STORAGE_BASE_URL?.replace(/\/$/, '') ||
  'https://storage.googleapis.com';

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

function getRunnerOs() {
  const runnerOs = process.env.RUNNER_OS?.toLowerCase();
  if (runnerOs === 'linux') return 'linux';
  if (runnerOs === 'macos') return 'macos';
  if (runnerOs === 'windows') return 'windows';

  switch (process.platform) {
    case 'linux':
      return 'linux';
    case 'darwin':
      return 'macos';
    case 'win32':
      return 'windows';
    default:
      fail(`Unsupported platform: ${process.platform}`);
  }
}

function getHostArch() {
  const runnerArch = process.env.RUNNER_ARCH?.toLowerCase();
  if (runnerArch === 'arm64') return 'arm64';
  if (runnerArch === 'x64' || runnerArch === 'x86') return 'x64';

  return process.arch === 'arm64' ? 'arm64' : 'x64';
}

function isStableCalVer(version) {
  return /^\d+\.\d+\.\d+$/.test(version);
}

function filterByArch(releases, hostArch) {
  return releases.filter((release) => {
    if (!release.dart_sdk_arch) return true;
    return release.dart_sdk_arch === hostArch;
  });
}

function pickLatestByDate(releases) {
  return releases.reduce((latest, current) => {
    if (!latest) return current;
    return Date.parse(current.release_date) > Date.parse(latest.release_date)
      ? current
      : latest;
  }, null);
}

function isPartialCandidate(version, channel) {
  if (channel === 'beta') {
    return /^\d+\.\d+\.\d+(-.+)?$/.test(version);
  }
  return isStableCalVer(version);
}

function resolveVersion(releases, versionSpec, channel) {
  const parts = versionSpec.split('.');

  if (parts.length === 3 && isStableCalVer(versionSpec)) {
    const exact = releases.filter((r) => r.version === versionSpec);
    if (exact.length === 0) {
      fail(`No Flutter release found for exact version "${versionSpec}" on the requested channel.`);
    }
    return pickLatestByDate(exact);
  }

  if (parts.length === 2) {
    const major = Number(parts[0]);
    const minor = Number(parts[1]);
    if (Number.isNaN(major) || Number.isNaN(minor)) {
      fail(`Invalid version format: "${versionSpec}"`);
    }
    const pattern = new RegExp(`^${major}\\.${minor}\\.\\d+(-.+)?$`);
    const candidates = releases.filter(
      (r) => pattern.test(r.version) && isPartialCandidate(r.version, channel),
    );
    if (candidates.length === 0) {
      fail(`No Flutter release found for minor version "${versionSpec}.x" on the requested channel.`);
    }
    return pickLatestByDate(candidates);
  }

  if (parts.length === 1) {
    const major = Number(parts[0]);
    if (Number.isNaN(major)) {
      fail(`Invalid version format: "${versionSpec}"`);
    }
    const pattern = new RegExp(`^${major}\\.\\d+\\.\\d+(-.+)?$`);
    const candidates = releases.filter(
      (r) => pattern.test(r.version) && isPartialCandidate(r.version, channel),
    );
    if (candidates.length === 0) {
      fail(`No Flutter release found for major version "${versionSpec}.x.x" on the requested channel.`);
    }
    return pickLatestByDate(candidates);
  }

  const partial = releases.filter((r) => r.version === versionSpec);
  if (partial.length === 0) {
    fail(`No Flutter release found for version "${versionSpec}" on the requested channel.`);
  }
  return pickLatestByDate(partial);
}

function writeOutput(name, value) {
  const outputFile = process.env.GITHUB_OUTPUT;
  if (outputFile) {
    appendFileSync(outputFile, `${name}=${value}\n`, 'utf8');
  } else {
    console.log(`${name}=${value}`);
  }
}

async function fetchManifest(osName) {
  const url = `${STORAGE_BASE}/flutter_infra_release/releases/releases_${osName}.json`;
  console.log(`Fetching Flutter release manifest: ${url}`);
  const response = await fetch(url);
  if (!response.ok) {
    fail(`Failed to fetch Flutter release manifest (${response.status} ${response.statusText}).`);
  }
  return response.json();
}

async function main() {
  const versionSpec = process.env.INPUT_VERSION?.trim();
  const channel = process.env.INPUT_CHANNEL?.trim() || 'stable';

  if (!versionSpec) {
    fail('Input "version" is required.');
  }
  if (!VALID_CHANNELS.has(channel)) {
    fail(`Unsupported channel "${channel}". Use "stable" or "beta".`);
  }

  const osName = getRunnerOs();
  const hostArch = getHostArch();
  const manifest = await fetchManifest(osName);

  let releases = manifest.releases.filter((release) => release.channel === channel);
  releases = filterByArch(releases, hostArch);

  if (releases.length === 0) {
    fail(`No Flutter releases found for channel "${channel}" on ${osName}.`);
  }

  const resolved = resolveVersion(releases, versionSpec, channel);
  const channelHeadHash = manifest.current_release?.[channel];
  const isChannelHead = Boolean(channelHeadHash && resolved.hash === channelHeadHash);

  console.log(`Resolved Flutter ${resolved.version} (${resolved.hash}) on channel ${channel}`);
  console.log(`Channel head: ${isChannelHead}`);

  writeOutput('version', resolved.version);
  writeOutput('hash', resolved.hash);
  writeOutput('channel', channel);
  writeOutput('is-channel-head', String(isChannelHead));
}

main().catch((error) => {
  fail(error instanceof Error ? error.message : String(error));
});
