// 配っている SKILL.md の frontmatter を検査する。`npx skills` と Claude Code が読むのは name と description なので、その 2 つを見る。
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parse } from "yaml";

const roots = ["skills", ...readdirSync("plugins").map((p) => join("plugins", p, "skills"))].filter(existsSync);
const problems = [];
let count = 0;
for (const root of roots) {
  for (const dir of readdirSync(root)) {
    const path = join(root, dir, "SKILL.md");
    if (!existsSync(path)) continue;
    count++;
    const match = readFileSync(path, "utf8").match(/^---\n([\s\S]*?)\n---\n/);
    if (!match) {
      problems.push(`${path}: frontmatter が無い`);
      continue;
    }
    const meta = parse(match[1]) ?? {};
    if (meta.name !== dir) problems.push(`${path}: name がディレクトリ名（${dir}）と違う: ${meta.name}`);
    if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(String(meta.name))) problems.push(`${path}: name は小文字とハイフンだけ`);
    if (typeof meta.description !== "string" || !meta.description.trim()) problems.push(`${path}: description が無い`);
  }
}
for (const p of problems) console.error(p);
console.log(`${count} 件の SKILL.md、${problems.length} 件の問題`);
process.exit(problems.length ? 1 : 0);
