import { defineConfig } from "tsup"

export default defineConfig([
  {
    entry: ["src/index.ts", "src/abis.ts", "src/enums.ts", "src/deployments.ts", "src/anvil.ts"],
    format: ["cjs", "esm"],
    dts: true,
    splitting: false,
    sourcemap: true,
    clean: true,
    tsconfig: "tsconfig.json",
    keepNames: true,
  },
  {
    entry: { "bin/cli": "cli/index.ts" },
    format: ["esm"],
    splitting: false,
    sourcemap: true,
    tsconfig: "tsconfig.json",
    keepNames: true,
  },
])
