import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach } from "vitest";
import { closeAllSockets, resetAll } from "./helpers";

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

beforeEach(async () => {
  await resetAll();
});

afterEach(async () => {
  await closeAllSockets();
});
