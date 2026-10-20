import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  optimizeDeps: {
    exclude: ["@matrix-org/matrix-sdk-crypto-wasm"],
  },
  server: {
    watch: {
      ignored: ["**/.buildozer/**", "**/bin/**", "**/.venv-buildozer/**"],
    },
  },
});