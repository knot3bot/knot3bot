#!/usr/bin/env node
// knot3bot npm installer — provides the correct platform binary.
// Priority: 1) bundled binary (if matching platform)  2) GitHub Releases download

const fs = require("fs");
const path = require("path");
const https = require("https");

const BINARY_NAME = "knot3bot_bin";
const GITHUB_REPO = "knot3bot/knot3bot";

function getVersion() {
  try {
    return JSON.parse(fs.readFileSync(path.join(__dirname, "package.json"), "utf8")).version;
  } catch { return "0.1.0"; }
}

function getPlatform() {
  const map = {
    "darwin-x64":   "knot3bot-x86_64-macos-gnu",
    "darwin-arm64": "knot3bot-aarch64-macos-gnu",
    "linux-x64":    "knot3bot-x86_64-linux-musl",
    "linux-arm64":  "knot3bot-aarch64-linux-musl",
  };
  return map[`${process.platform}-${process.arch}`] || null;
}

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest, { mode: 0o755 });
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        https.get(res.headers.location, (r2) => { r2.pipe(file); file.on("finish", () => { file.close(); resolve(); }); }).on("error", reject);
        return;
      }
      if (res.statusCode === 404) return reject(new Error("not found"));
      res.pipe(file);
      file.on("finish", () => { file.close(); resolve(); });
    }).on("error", reject);
  });
}

async function main() {
  const binDir = path.join(__dirname, "bin");
  const binPath = path.join(binDir, BINARY_NAME);

  // Already installed
  if (fs.existsSync(binPath)) {
    console.log(`knot3bot: binary ready (${binPath})`);
    return;
  }

  fs.mkdirSync(binDir, { recursive: true });

  const platform = getPlatform();
  const version = getVersion();

  // 1) Try GitHub Release download (best: gets the right platform binary)
  if (platform) {
    const url = `https://github.com/${GITHUB_REPO}/releases/download/v${version}/${platform}`;
    console.log(`knot3bot: downloading ${platform} v${version}...`);
    try {
      await download(url, binPath);
      fs.chmodSync(binPath, 0o755);
      console.log(`knot3bot: installed via GitHub Release`);
      return;
    } catch (e) {
      console.log(`knot3bot: GitHub Release not available (${e.message}), trying fallback...`);
    }
  }

  // 2) Fallback: check if a binary was bundled with the package (dev/CI convenience)
  const bundledPaths = ["knot3bot_bin", "knot3bot"].map(f => path.join(binDir, f));
  for (const bp of bundledPaths) {
    if (fs.existsSync(bp) && bp !== binPath) {
      fs.copyFileSync(bp, binPath);
      fs.chmodSync(binPath, 0o755);
      console.log(`knot3bot: using bundled binary (${bp})`);
      return;
    }
  }

  // 3) Nothing worked
  console.log(`knot3bot: no prebuilt binary available for ${process.platform}-${process.arch}.`);
  console.log(`Build from source: https://github.com/${GITHUB_REPO}#building`);
  process.exit(0);
}

main();
