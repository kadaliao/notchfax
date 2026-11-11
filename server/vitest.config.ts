import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// 仅用于测试的假密钥；同时设到 process.env 让 wrangler 的 secrets.required 检查不再告警
process.env.SESSION_SECRET = "test-only-session-secret-not-used-anywhere-else";

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            SESSION_SECRET: process.env.SESSION_SECRET,
            TEST_MIGRATIONS: migrations,
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/setup.ts"],
      include: ["test/**/*.test.ts"],
      testTimeout: 15_000,
      // 所有测试文件共用同一份本地 D1/R2，串行执行并在每个测试前清库
      fileParallelism: false,
    },
  };
});
