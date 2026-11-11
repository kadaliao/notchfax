// `pnpm dev` 的前置步骤：本地没有 .dev.vars 时生成一份带随机 SESSION_SECRET 的。
// 不会覆盖已有文件，也不会把密钥打印出来。
import { existsSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

const target = fileURLToPath(new URL("../.dev.vars", import.meta.url));
if (!existsSync(target)) {
  writeFileSync(target, `SESSION_SECRET=${randomBytes(32).toString("base64url")}\n`, { mode: 0o600 });
  console.log("created .dev.vars with a random SESSION_SECRET");
}
