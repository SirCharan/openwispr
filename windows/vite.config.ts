import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // Tauri expects a fixed port and fails the build rather than silently using another.
  server: { port: 1420, strictPort: true },
  build: { target: "chrome120", sourcemap: false },
  test: {
    environment: "jsdom",
    globals: true,
    include: ["src/**/*.test.{ts,tsx}"],
  },
});
