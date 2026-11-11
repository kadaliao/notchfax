import type { D1Migration } from "cloudflare:test";

declare global {
  namespace Cloudflare {
    interface Env {
      SESSION_SECRET: string;
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}
