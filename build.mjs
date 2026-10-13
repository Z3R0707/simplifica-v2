// Monta o site em dist/ com esbuild (o mesmo usado nos testes locais).
// Variáveis obrigatórias (configuradas no Netlify → Environment variables):
//   SUPABASE_URL       ex.: https://xxxx.supabase.co
//   SUPABASE_ANON_KEY  chave pública "anon" do projeto (pode ficar no navegador)
import { build } from "esbuild";
import { mkdirSync, rmSync, readFileSync, writeFileSync, copyFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";

const url = (process.env.SUPABASE_URL ?? "").trim().replace(/\/+$/, "");
const anon = (process.env.SUPABASE_ANON_KEY ?? "").trim();
const faltando = [];
if (!/^https?:\/\/[^/]+$/.test(url)) faltando.push("SUPABASE_URL (ex.: https://xxxx.supabase.co)");
if (anon.length < 20) faltando.push("SUPABASE_ANON_KEY (chave pública anon do Supabase)");
if (faltando.length) {
  console.error("\nBuild interrompido: configure no Netlify (Project configuration → Environment variables):\n  - " + faltando.join("\n  - ") + "\n");
  process.exit(1);
}

rmSync("dist", { recursive: true, force: true });
mkdirSync("dist", { recursive: true });

const resultado = await build({
  entryPoints: ["src/main.tsx"],
  bundle: true,
  minify: process.env.SEM_MINIFICAR !== "1",
  sourcemap: false,
  format: "esm",
  target: ["es2022", "safari15"],
  jsx: "automatic",
  outdir: "dist/assets",
  entryNames: "app-[hash]",
  assetNames: "[name]-[hash]",
  metafile: true,
  legalComments: "none",
  define: {
    __SUPABASE_URL__: JSON.stringify(url),
    __SUPABASE_ANON_KEY__: JSON.stringify(anon),
    "process.env.NODE_ENV": '"production"',
  },
  nodePaths: process.env.NODE_PATH ? process.env.NODE_PATH.split(":") : [],
  logLevel: "warning",
});

const saidas = Object.keys(resultado.metafile.outputs);
const js = saidas.find((s) => s.endsWith(".js"));
const css = saidas.find((s) => s.endsWith(".css"));
if (!js || !css) {
  console.error("Build incompleto: JS ou CSS não gerado.");
  process.exit(1);
}
const nomeWeb = (p) => "/" + p.replace(/^dist\//, "");
const html = readFileSync("index.html", "utf8")
  .replace("<!--CSS-->", `<link rel="stylesheet" href="${nomeWeb(css)}">`)
  .replace("<!--JS-->", `<script type="module" src="${nomeWeb(js)}"></script>`);
writeFileSync("dist/index.html", html);
if (existsSync("public")) {
  for (const f of ["favicon.svg", "robots.txt"]) if (existsSync(`public/${f}`)) copyFileSync(`public/${f}`, `dist/${f}`);
}
const versao = createHash("sha256").update(readFileSync(js)).digest("hex").slice(0, 12);
writeFileSync("dist/versao.txt", versao + "\n");
console.log(`Build concluído: ${nomeWeb(js)} e ${nomeWeb(css)} (versão ${versao}) — Supabase: ${url}`);
